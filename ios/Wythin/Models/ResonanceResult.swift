import Foundation
import SwiftData

/// Best resonance breathing frequency found during a RESONATE scan.
@Model
final class ResonanceResult {
    @Attribute(.unique) var id: UUID
    var sessionID:     UUID
    var recordedAt:    Date
    var bestBPM:       Float    // e.g. 5.5
    var bestCoherence: Float    // peak coherence score at that frequency
    var bestRSAms:     Float?   // RSA amplitude at resonance

    init(sessionID: UUID, bestBPM: Float, bestCoherence: Float, bestRSAms: Float? = nil) {
        self.id             = UUID()
        self.sessionID      = sessionID
        self.recordedAt     = Date()
        self.bestBPM        = bestBPM
        self.bestCoherence  = bestCoherence
        self.bestRSAms      = bestRSAms
    }
}
