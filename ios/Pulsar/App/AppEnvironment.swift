import Foundation
import SwiftData
import Combine

// MARK: - WaveformDisplay
//
// Separate @Observable so 30-fps waveform updates don't invalidate views
// that only care about 2-s metric ticks (charts, rings, etc.).

@Observable
final class WaveformDisplay {
    var ecg: [Float] = []
    var acc: [Float] = []
    var rr:  [Float] = []
}

// MARK: - AppEnvironment
//
// Single dependency container injected at the root.
// All services are long-lived and share state.

@MainActor
@Observable
final class AppEnvironment {

    // MARK: Services

    let ble        = BLEService()
    let dataBuffer = DataBuffer()
    let sync:        SyncService

    // MARK: Waveform display (updated at ~30 fps, isolated so chart views stay at 2 s)

    let waveform = WaveformDisplay()

    // MARK: Session state (updated at ~2 s)

    var currentSession:  HRVSession?
    var latestTick:      MetricsTick?

    // MARK: Cross-tab navigation

    /// Set by any tab to request ContentView switch the selected tab.
    /// ContentView observes this and resets it to nil after acting on it.
    var pendingTabRequest: AppTab? = nil

    /// Lightweight scalar-only history for charts. Capped at 24 h of 2-s ticks.
    /// Uses a ring-buffer trim strategy (batch removal every trimBatch ticks)
    /// to avoid O(n) removeFirst on every append once the buffer is full.
    var tickHistory: [MetricsHistoryPoint] = []

    var isInForeground: Bool = true {
        didSet {
            if !isInForeground {
                // Flush pending writes immediately when leaving foreground
                // so data isn't lost if the OS terminates the process.
                if pendingSaveCount > 0 {
                    try? modelContainer.mainContext.save()
                    pendingSaveCount = 0
                }
            } else {
                // Returning to foreground — merge any samples saved during background
                // into tickHistory so intraday charts show the full picture.
                reloadRecentHistory()
                retryPendingInsights()
            }
        }
    }

    // MARK: Config (persisted)

    var serverURL: URL {
        get {
            let s = UserDefaults.standard.string(forKey: "serverURL") ?? "https://api.77.42.73.250.sslip.io"
            return URL(string: s) ?? URL(string: "https://api.77.42.73.250.sslip.io")!
        }
        set { UserDefaults.standard.set(newValue.absoluteString, forKey: "serverURL") }
    }

    var userID: String {
        get {
            if let id = UserDefaults.standard.string(forKey: "userID") { return id }
            let id = UUID().uuidString
            UserDefaults.standard.set(id, forKey: "userID")
            return id
        }
    }

    // MARK: Private

    private let modelContainer: ModelContainer
    private var autoSession:    HRVSession?
    private var cancellables = Set<AnyCancellable>()
    private var metricsTask:  Task<Void, Never>?
    private var displayTask:  Task<Void, Never>?

    private let maxTickHistory  = 43_200   // 24 h at 2 s/tick
    private let trimBatch       = 600      // trim this many entries at once (amortises O(n) shift)
    private let saveInterval    = 30       // persist to disk every 60 s (30 ticks × 2 s)
    private var pendingSaveCount = 0       // ticks accumulated since last save
    private var lastBackgroundTick: Date = .distantPast  // throttles bg computation to 30 s

    // MARK: Init

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.sync = SyncService(serverURL: UserDefaults.standard.string(forKey: "serverURL")
            .flatMap(URL.init) ?? URL(string: "https://api.77.42.73.250.sslip.io")!)

        bindBLE()
        loadHistory()
        Task {
            let context = modelContainer.mainContext
            let uploader = SessionUploader(client: sync.client, userID: userID)
            await uploader.flushPending(context: context)
        }
    }

    // MARK: Session control

    func startSession(context: ModelContext) {
        // End auto-session cleanly before switching to explicit
        if let bg = autoSession {
            bg.endedAt = Date()
            try? context.save()
        }
        autoSession = nil

        let session = HRVSession()
        context.insert(session)
        currentSession = session
        sync.beginSession(userID: userID)
    }

    func endSession(context: ModelContext) {
        guard let session = currentSession else { return }
        session.endedAt = Date()
        // Summarise
        let samples = session.samples
        if !samples.isEmpty {
            session.avgRSAms     = samples.compactMap(\.rsaMs).average()
            session.avgCoherence = samples.compactMap(\.coherence).average()
        }
        do {
            try context.save()
        } catch {
            print("❌ Failed to save session: \(error)")
        }
        currentSession = nil
        autoSession = nil
        Task {
            do {
                try await sync.uploadSession(session)
            } catch {
                print("❌ Failed to upload session: \(error)")
            }
        }
    }

    // MARK: Private — History loading

    private func loadHistory() {
        let context = modelContainer.mainContext
        let cutoff  = Date().addingTimeInterval(-86_400)
        var descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp >= cutoff },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = maxTickHistory
        let samples = (try? context.fetch(descriptor)) ?? []
        tickHistory = samples.map { MetricsHistoryPoint(from: $0) }
    }

    /// Merge samples written during background into tickHistory.
    /// Called when the app returns to foreground so live charts stay complete.
    private func reloadRecentHistory() {
        let context   = modelContainer.mainContext
        // Only fetch samples newer than the last point we already have.
        let afterDate = tickHistory.last?.timestamp ?? Date().addingTimeInterval(-86_400)
        var descriptor = FetchDescriptor<HRVSample>(
            predicate: #Predicate { $0.timestamp > afterDate },
            sortBy:    [SortDescriptor(\.timestamp)]
        )
        descriptor.fetchLimit = maxTickHistory
        let newSamples = (try? context.fetch(descriptor)) ?? []
        guard !newSamples.isEmpty else { return }
        let pts = newSamples.map { MetricsHistoryPoint(from: $0) }
        tickHistory.append(contentsOf: pts)
        if tickHistory.count > maxTickHistory + trimBatch {
            tickHistory.removeFirst(tickHistory.count - maxTickHistory)
        }
    }

    /// Retry any activities that finished without a generated insight,
    /// e.g. because the device was offline when the activity ended.
    private func retryPendingInsights() {
        let context = modelContainer.mainContext
        Task { await InsightGenerator(client: sync.client).flushPending(context: context) }
    }

    // MARK: BLE → DataBuffer → MetricsEngine pipeline

    private func bindBLE() {
        // Forward ECG frames to buffer
        ble.ecgSubject
            .sink { [weak self] samples in
                guard let self else { return }
                Task { await self.dataBuffer.appendECG(samples) }
            }
            .store(in: &cancellables)

        // Forward ACC frames
        ble.accSubject
            .sink { [weak self] xyz in
                guard let self else { return }
                Task { await self.dataBuffer.appendACC(xyz: xyz) }
            }
            .store(in: &cancellables)

        // Forward RR intervals + BPM
        ble.hrSubject
            .sink { [weak self] frame in
                guard let self else { return }
                Task {
                    await self.dataBuffer.appendRR(frame.rrIntervalsMs)
                    await self.dataBuffer.appendBPM(Float(frame.bpm))
                }
            }
            .store(in: &cancellables)

        // A connection gap (unexpected drop, silent watchdog-detected drop, or BT
        // power cycling) invalidates every buffered signal: RR/ECG/ACC around the
        // gap don't represent a continuous recording, and the first RR interval(s)
        // delivered after resuming can reflect elapsed time across the gap rather
        // than a real beat-to-beat interval. Drop everything rather than let a
        // few bad samples sit in the 1200-beat HRV window for up to ~20 minutes.
        ble.connectionGapSubject
            .sink { [weak self] in
                guard let self else { return }
                Task { await self.dataBuffer.clear() }
            }
            .store(in: &cancellables)

        // ── Metrics tick ─────────────────────────────────────────────────────
        // Foreground: every 2 s — full fidelity, updates live UI.
        // Background: every 30 s — throttled to save battery, still records to disk.
        // The app stays alive in background because the bluetooth-central background
        // mode keeps it running while BLE data arrives.
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { break }

                let inForeground = self.isInForeground

                // In background, only process every 30 s to avoid unnecessary
                // FFT/PSD computation draining the battery.
                if !inForeground {
                    let elapsed = Date().timeIntervalSince(self.lastBackgroundTick)
                    guard elapsed >= 30 else { continue }
                    self.lastBackgroundTick = Date()
                }

                let snapshot = await self.dataBuffer.snapshot()

                // Use lower CPU priority in background so BLE callbacks stay responsive.
                let priority: TaskPriority = inForeground ? .userInitiated : .utility
                let tick = await Task.detached(priority: priority) {
                    MetricsEngine.compute(from: snapshot)
                }.value

                // ── Foreground-only: update live display ──────────────────────
                if inForeground {
                    self.latestTick = tick
                    self.tickHistory.append(MetricsHistoryPoint(from: tick))
                    if self.tickHistory.count > self.maxTickHistory + self.trimBatch {
                        self.tickHistory.removeFirst(self.trimBatch)
                    }
                    self.sync.sendTick(tick, userID: self.userID)
                }

                // ── Always: persist to SwiftData ──────────────────────────────
                // Background samples are merged into tickHistory when app resumes
                // (see reloadRecentHistory called from isInForeground.didSet).
                let context = self.modelContainer.mainContext
                if self.currentSession == nil && self.autoSession == nil {
                    let bg = HRVSession()
                    bg.notes = "auto"
                    context.insert(bg)
                    self.autoSession = bg
                }
                let activeSession = self.currentSession ?? self.autoSession!
                activeSession.samples.append(HRVSample(from: tick))
                self.pendingSaveCount += 1
                if self.pendingSaveCount >= self.saveInterval {
                    try? context.save()
                    self.pendingSaveCount = 0
                }
            }
        }

        // ── Waveform display at ~10 fps ───────────────────────────────────────
        // 100 ms (10 fps) is imperceptible for waveform scrolling and cuts
        // MainActor wakeups by 67% vs the previous 33 ms (30 fps).
        // The TimelineView inside ECG/ACC views drives its own Canvas redraws
        // independently; only the data buffer refresh rate changes here.
        // Writes go to `waveform` (separate @Observable) so invalidation is
        // scoped only to TodayLiveSection, not DayScrollView or charts.
        displayTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isInForeground else { continue }
                let ecg = await self.dataBuffer.ecgDisplay(samples: 650)
                let acc = await self.dataBuffer.accDisplay(samples: 600)
                let rr  = await self.dataBuffer.rrDisplay()
                // Three synchronous assignments on MainActor — coalesced into one
                // SwiftUI render pass by the observation system.
                self.waveform.ecg = ecg
                self.waveform.acc = acc
                self.waveform.rr  = rr
            }
        }
    }
}

// MARK: - Helpers

private extension Array where Element == Float {
    func average() -> Float? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Float(count)
    }
}
