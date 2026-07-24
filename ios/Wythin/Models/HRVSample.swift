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
    var dfa1:           Float?
    var signalQuality:  Float?
    var rrInvalidRate:   Float?   // fraction of RR dropped as implausible
    var rrCorrectedRate: Float?   // fraction of RR interpolated (missed/extra beat)
    var ecgQualityTier:  Int?     // SignalQualityTier.rawValue (0 poor…2 good)
    var rcmse:          Float?
    var pip:            Float?
    var ials:           Float?
    var dc:             Float?
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
        self.dfa1          = tick.dfa1
        self.signalQuality = tick.signalQuality
        self.rrInvalidRate   = tick.rrInvalidRate
        self.rrCorrectedRate = tick.rrCorrectedRate
        self.ecgQualityTier  = tick.ecgQuality?.tier.rawValue
        self.rcmse         = tick.rcmse
        self.pip           = tick.pip
        self.ials          = tick.ials
        self.dc            = tick.dc
        self.vti        = tick.vti
        self.ulfPower   = tick.ulfPower
        self.vlfPower   = tick.vlfPower
        self.lfPower    = tick.lfPower
        self.hfPower    = tick.hfPower
    }
}
