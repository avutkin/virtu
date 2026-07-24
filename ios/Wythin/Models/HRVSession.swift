import Foundation
import SwiftData

/// A complete biometric session — from connect to disconnect.
@Model
final class HRVSession {
    @Attribute(.unique) var id: UUID
    var startedAt:  Date
    var endedAt:    Date?

    // Summary metrics (computed at session end)
    var bestResonanceBPM: Float?
    var avgRSAms:         Float?
    var avgCoherence:     Float?
    var notes:            String?

    // Upload state
    var syncedToServer: Bool
    var serverSessionID: String?   // UUID string from server

    @Relationship(deleteRule: .cascade) var samples: [HRVSample]

    init(id: UUID = UUID(), startedAt: Date = Date()) {
        self.id          = id
        self.startedAt   = startedAt
        self.syncedToServer = false
        self.samples     = []
    }

    var duration: TimeInterval {
        (endedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var isActive: Bool { endedAt == nil }
}
