import Foundation
import SwiftData

// MARK: - ActivityLogging
//
// Single source of truth for creating/finishing ActivityLog records, shared by
// the Activities tab and the Practices hub. Behaviour matches the original
// ActivitiesView.beginActivity / endActivity / logPast exactly.

/// Seed values for prefilling the "Log it" sheet from a Practice.
struct ActivityPrefill {
    let type:         ActivityType
    let subtype:      String?
    let durationMins: Double?
}

enum ActivityLogging {

    /// Start a live activity (isManual = false, endedAt = nil → active).
    @discardableResult
    static func begin(type: ActivityType, subtype: String?, customName: String?,
                      context: ModelContext) -> ActivityLog {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       .now,
            isManual:        false
        )
        context.insert(entry)
        try? context.save()
        return entry
    }

    /// Finish a live activity: stamp endedAt, fill HRV windows, save, generate insight.
    static func end(_ entry: ActivityLog, context: ModelContext, client: InsightAPIClient) {
        entry.endedAt = .now
        entry.computeHRVWindows(context: context)
        try? context.save()
        Task { await InsightGenerator(client: client).generate(for: entry, context: context) }
    }

    /// Log a past/retrospective activity (isManual = true) with explicit window.
    static func logPast(type: ActivityType, subtype: String?, customName: String?,
                        start: Date, end: Date,
                        context: ModelContext, client: InsightAPIClient) {
        let entry = ActivityLog(
            activityType:    type.rawValue,
            activitySubtype: subtype,
            customName:      customName,
            startedAt:       start,
            endedAt:         end,
            isManual:        true
        )
        entry.computeHRVWindows(context: context)
        context.insert(entry)
        try? context.save()
        Task { await InsightGenerator(client: client).generate(for: entry, context: context) }
    }
}
