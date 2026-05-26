import Foundation
import SwiftData

/// One metrics tick (~2 s snapshot) within a session.
@Model
final class HRVSample {
    var timestamp:      Date
    var meanBPM:        Float?
    var rmssd:          Float?
    var sdnn:           Float?
    var pnn50:          Float?
    var lfHF:           Float?
    var rsaMs:          Float?
    var rsaIdx:         Float?
    var coherence:      Float?
    var cbi:            Float?
    var breathBPM:      Float?
    var ieRatio:        Float?   // BreathPhases.meanIE
    var vti:            Float?   // ln(RMSSD)
    var ulfPower:       Float?   // ms²  (ULF < 0.003 Hz)
    var vlfPower:       Float?   // ms²  (VLF 0.003–0.04 Hz)
    var lfPower:        Float?   // ms²
    var hfPower:        Float?   // ms²

    init(from tick: MetricsTick) {
        self.timestamp  = tick.timestamp
        self.meanBPM    = tick.meanBPM
        self.rmssd      = tick.rmssd
        self.sdnn       = tick.sdnn
        self.pnn50      = tick.pnn50
        self.lfHF       = tick.lfHF
        self.rsaMs      = tick.rsaMs
        self.rsaIdx     = tick.rsaIdx
        self.coherence  = tick.coherenceScore
        self.cbi        = tick.cbi
        self.breathBPM  = tick.breathBPM
        self.ieRatio    = tick.breathPhases?.meanIE
        self.vti        = tick.vti
        self.ulfPower   = tick.ulfPower
        self.vlfPower   = tick.vlfPower
        self.lfPower    = tick.lfPower
        self.hfPower    = tick.hfPower
    }
}
