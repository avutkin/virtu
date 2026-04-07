import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \HRVSession.startedAt, order: .reverse)
    var sessions: [HRVSession]

    @Query(sort: \TrainSession.startedAt, order: .reverse)
    var trainSessions: [TrainSession]

    @State private var selectedRange: TimeRange = .week

    @State private var selectedTab: HistoryTab = .hrv

    enum HistoryTab: String, CaseIterable {
        case hrv   = "HRV"
        case train = "TRAIN"
    }

    enum TimeRange: String, CaseIterable {
        case week  = "7D"
        case month = "30D"
        case quarter = "90D"
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()

                List {
                    // ── HRV / TRAIN tab picker ────────────────────────
                    Section {
                        Picker("Tab", selection: $selectedTab) {
                            ForEach(HistoryTab.allCases, id: \.self) {
                                Text($0.rawValue).tag($0)
                            }
                        }
                        .pickerStyle(.segmented)
                        .padding(.vertical, 4)
                    }
                    .listRowBackground(Theme.card)

                    if selectedTab == .hrv {
                        // ── Range picker ─────────────────────────────────
                        Section {
                            Picker("Range", selection: $selectedRange) {
                                ForEach(TimeRange.allCases, id: \.self) {
                                    Text($0.rawValue).tag($0)
                                }
                            }
                            .pickerStyle(.segmented)
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Theme.card)

                        // ── RSA trend chart ───────────────────────────────
                        Section("RSA TREND") {
                            RSATrendChart(sessions: filteredSessions)
                                .frame(height: 150)
                        }
                        .listRowBackground(Theme.card)

                        // ── Coherence trend ───────────────────────────────
                        Section("COHERENCE") {
                            CoherenceTrendChart(sessions: filteredSessions)
                                .frame(height: 120)
                        }
                        .listRowBackground(Theme.card)

                        // ── Session list ──────────────────────────────────
                        Section("SESSIONS") {
                            ForEach(filteredSessions) { session in
                                SessionRow(session: session)
                            }
                        }
                        .listRowBackground(Theme.card)
                    }

                    if selectedTab == .train {
                        Section("TRAIN SESSIONS") {
                            if trainSessions.isEmpty {
                                Text("No training sessions yet")
                                    .font(Theme.monoLabel)
                                    .foregroundStyle(Theme.dim)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.vertical, 20)
                            } else {
                                ForEach(trainSessions) { session in
                                    TrainSessionRow(session: session)
                                }
                            }
                        }
                        .listRowBackground(Theme.card)
                    }
                }
                .scrollContentBackground(.hidden)
                .background(Theme.bg)
            }
            .navigationTitle("HISTORY")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    private var filteredSessions: [HRVSession] {
        let cutoff: Date
        switch selectedRange {
        case .week:    cutoff = Calendar.current.date(byAdding: .day, value: -7,  to: Date())!
        case .month:   cutoff = Calendar.current.date(byAdding: .day, value: -30, to: Date())!
        case .quarter: cutoff = Calendar.current.date(byAdding: .day, value: -90, to: Date())!
        }
        return sessions.filter { $0.startedAt >= cutoff }
    }
}

// MARK: - RSA Trend Chart

private struct RSATrendChart: View {
    let sessions: [HRVSession]

    var body: some View {
        Chart {
            ForEach(sessions.filter { $0.avgRSAms != nil }) { s in
                LineMark(
                    x: .value("Date", s.startedAt),
                    y: .value("RSA (ms)", s.avgRSAms!)
                )
                .foregroundStyle(Theme.rsa)
                PointMark(
                    x: .value("Date", s.startedAt),
                    y: .value("RSA (ms)", s.avgRSAms!)
                )
                .foregroundStyle(Theme.rsa)
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                    .foregroundStyle(Theme.dim)
            }
        }
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel { Text("\(v.as(Double.self).map { Int($0) } ?? 0)").foregroundStyle(Theme.dim) }
            }
        }
        .chartBackground { _ in Theme.card }
    }
}

// MARK: - Coherence Trend Chart

private struct CoherenceTrendChart: View {
    let sessions: [HRVSession]

    var body: some View {
        Chart {
            ForEach(sessions.filter { $0.avgCoherence != nil }) { s in
                BarMark(
                    x: .value("Date", s.startedAt),
                    y: .value("Coherence", s.avgCoherence!)
                )
                .foregroundStyle(
                    s.avgCoherence! >= 0.7 ? Theme.accent :
                    s.avgCoherence! >= 0.4 ? Theme.warn   : Theme.warn.opacity(0.5)
                )
            }
        }
        .chartYScale(domain: 0...1)
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
                AxisValueLabel(format: .dateTime.day())
                    .foregroundStyle(Theme.dim)
            }
        }
        .chartYAxis {
            AxisMarks(values: [0, 0.5, 1]) { _ in
                AxisGridLine().foregroundStyle(Theme.border)
            }
        }
        .chartBackground { _ in Theme.card }
    }
}

// MARK: - Session Row

private struct SessionRow: View {
    let session: HRVSession

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Text(durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                if let rsa = session.avgRSAms {
                    Text(String(format: "RSA %.1f ms", rsa))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.rsa)
                }
                if let coh = session.avgCoherence {
                    Text(String(format: "COH %.2f", coh))
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.coh)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var durationString: String {
        let d = Int(session.duration)
        return String(format: "%d:%02d", d / 60, d % 60)
    }
}

// MARK: - Train Session Row

private struct TrainSessionRow: View {
    let session: TrainSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.startedAt, format: .dateTime.month().day().hour().minute())
                    .font(Theme.monoBody)
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(session.durationString)
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }

            HStack(spacing: 16) {
                Label("\(session.setCount) sets", systemImage: "bolt")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn)
                if session.avgRecoveryMin > 0 {
                    Label(String(format: "%.1f min avg recovery", session.avgRecoveryMin),
                          systemImage: "arrow.down.heart")
                        .font(Theme.monoLabel)
                        .foregroundStyle(Theme.rsa)
                }
            }

            HStack(spacing: 16) {
                Text(String(format: "SNS %.2f", session.avgSNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.warn.opacity(0.8))
                Text(String(format: "PNS %.2f", session.avgPNSIndex))
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.accent.opacity(0.8))
            }

            let recs = session.recoveryMinArray
            if !recs.isEmpty {
                Text("Sets: " + recs.map { String(format: "%.1f", $0) }.joined(separator: " → ") + " min")
                    .font(Theme.monoLabel)
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(.vertical, 4)
    }
}
