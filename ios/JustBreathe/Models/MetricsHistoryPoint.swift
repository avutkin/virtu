import Foundation

// MARK: - MetricsQualityFilter

/// Heuristic wear-detection for Polar H10.
/// When the strap is removed, SDNN collapses near zero (no real cardiac variability).
/// Three simultaneous threshold tests gate each tick.
enum MetricsQualityFilter {

    static func isValid(_ pt: MetricsHistoryPoint) -> Bool {
        guard let sdnn  = pt.sdnn,    sdnn  > 5.0  else { return false }
        guard let rmssd = pt.rmssd,   rmssd > 3.0  else { return false }
        guard let bpm   = pt.meanBPM, bpm  >= 35.0,
              bpm <= 160.0                          else { return false }
        return true
    }

    static func filter(_ pts: [MetricsHistoryPoint]) -> [MetricsHistoryPoint] {
        pts.filter { isValid($0) }
    }
}

// MARK: - MetricsHistoryPoint

/// Lightweight snapshot of scalar metrics from one compute tick (every ~2 s).
/// Strips array fields (PSD, breathPhases.filtered) so 24 h of history ≈ 4 MB.
struct MetricsHistoryPoint {
    let timestamp:  Date

    let ieRatio:    Float?   // BreathPhases.meanIE  (exhale/inhale)
    let vti:        Float?   // ln(RMSSD)
    let rmssd:      Float?   // ms
    let rsaMs:      Float?   // ms
    let sdnn:       Float?   // ms
    let pnn50:      Float?   // %
    let ulfPower:   Float?   // ms²  (ULF < 0.003 Hz)
    let vlfPower:   Float?   // ms²  (VLF 0.003–0.04 Hz)
    let lfPower:    Float?   // ms²
    let hfPower:    Float?   // ms²
    let lfHF:       Float?   // ratio
    let coherence:  Float?   // 0–1
    let cbi:        Float?   // 0–1
    let breathBPM:  Float?   // br/min
    let meanBPM:    Float?   // bpm
    let dfa1:          Float?
    let signalQuality: Float?
    let rcmse:         Float?   // RCMSE mean entropy (scales 1–5)
    let pip:           Float?   // HR Fragmentation: % inflection points
    let ials:          Float?   // HR Fragmentation: inverse avg segment length
    let dc:            Float?   // Deceleration Capacity (ms)

    init(from tick: MetricsTick) {
        timestamp  = tick.timestamp
        ieRatio    = tick.breathPhases?.meanIE
        vti        = tick.vti
        rmssd      = tick.rmssd
        rsaMs      = tick.rsaMs
        sdnn       = tick.sdnn
        pnn50      = tick.pnn50
        ulfPower   = tick.ulfPower
        vlfPower   = tick.vlfPower
        lfPower    = tick.lfPower
        hfPower    = tick.hfPower
        lfHF       = tick.lfHF
        coherence  = tick.coherenceScore
        cbi        = tick.cbi
        breathBPM  = tick.breathBPM
        meanBPM    = tick.meanBPM
        dfa1          = tick.dfa1
        signalQuality = tick.signalQuality
        rcmse         = tick.rcmse
        pip           = tick.pip
        ials          = tick.ials
        dc            = tick.dc
    }

    init(from sample: HRVSample) {
        timestamp  = sample.timestamp
        ieRatio    = sample.ieRatio
        vti        = sample.vti
        rmssd      = sample.rmssd
        rsaMs      = sample.rsaMs
        sdnn       = sample.sdnn
        pnn50      = sample.pnn50
        ulfPower   = sample.ulfPower
        vlfPower   = sample.vlfPower
        lfPower    = sample.lfPower
        hfPower    = sample.hfPower
        lfHF       = sample.lfHF
        coherence  = sample.coherence
        cbi        = sample.cbi
        breathBPM  = sample.breathBPM
        meanBPM    = sample.meanBPM
        dfa1          = sample.dfa1
        signalQuality = sample.signalQuality
        rcmse         = sample.rcmse
        pip           = sample.pip
        ials          = sample.ials
        dc            = sample.dc
    }

    /// Convenience initializer for constructing a snapshot directly by field,
    /// without going through MetricsTick's full field list. Unlisted fields
    /// default to nil.
    init(
        timestamp: Date,
        meanBPM:   Float? = nil,
        rmssd:     Float? = nil,
        rsaMs:     Float? = nil,
        sdnn:      Float? = nil,
        lfHF:      Float? = nil,
        coherence: Float? = nil,
        breathBPM: Float? = nil,
        cbi:       Float? = nil
    ) {
        self.timestamp = timestamp
        self.ieRatio = nil
        self.vti = nil
        self.rmssd = rmssd
        self.rsaMs = rsaMs
        self.sdnn = sdnn
        self.pnn50 = nil
        self.ulfPower = nil
        self.vlfPower = nil
        self.lfPower = nil
        self.hfPower = nil
        self.lfHF = lfHF
        self.coherence = coherence
        self.cbi = cbi
        self.breathBPM = breathBPM
        self.meanBPM = meanBPM
        self.dfa1 = nil
        self.signalQuality = nil
        self.rcmse = nil
        self.pip = nil
        self.ials = nil
        self.dc = nil
    }
}
