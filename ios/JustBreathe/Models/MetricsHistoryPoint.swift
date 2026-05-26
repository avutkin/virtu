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
    }
}
