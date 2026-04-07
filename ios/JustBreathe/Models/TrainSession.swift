import Foundation
import SwiftData

/// Summary of one training session recorded on the Train tab.
@Model
final class TrainSession {
    @Attribute(.unique) var id: UUID
    var startedAt:      Date
    var endedAt:        Date?
    var baselineHR:     Float
    var baselineRMSSD:  Float?
    var setCount:       Int        // number of ACTIVE→RECOVER transitions logged
    var avgSNSIndex:    Float      // mean LFnu (0–1) over session
    var avgPNSIndex:    Float      // mean HFnu (0–1) over session
    var avgRecoveryMin: Float      // mean recovery duration in minutes
    var recoveryMins:   String     // JSON-encoded [Float], e.g. "[3.2,4.8,5.1]"

    init(
        id:            UUID  = UUID(),
        startedAt:     Date  = Date(),
        baselineHR:    Float,
        baselineRMSSD: Float? = nil
    ) {
        self.id            = id
        self.startedAt     = startedAt
        self.baselineHR    = baselineHR
        self.baselineRMSSD = baselineRMSSD
        self.setCount      = 0
        self.avgSNSIndex   = 0
        self.avgPNSIndex   = 0
        self.avgRecoveryMin = 0
        self.recoveryMins  = "[]"
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var durationString: String {
        let mins = Int((duration / 60).rounded())
        return "\(mins) min"
    }

    var isActive: Bool { endedAt == nil }

    var recoveryMinArray: [Float] {
        guard let data = recoveryMins.data(using: .utf8) else {
            assertionFailure("TrainSession.recoveryMins is not valid UTF-8: \(recoveryMins)")
            return []
        }
        guard let result = try? JSONDecoder().decode([Float].self, from: data) else {
            assertionFailure("TrainSession.recoveryMins is not valid JSON [Float]: \(recoveryMins)")
            return []
        }
        return result
    }
}
