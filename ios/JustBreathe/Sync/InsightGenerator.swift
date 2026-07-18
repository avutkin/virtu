import Foundation
import SwiftData

/// Generates OpenAI-backed insights for completed activities, and retries
/// any that failed while offline. Same shape as `SessionUploader` — an
/// actor wrapping a client, used for foreground-triggered catch-up work.
actor InsightGenerator {

    private let client: InsightAPIClient

    init(client: InsightAPIClient) {
        self.client = client
    }

    /// Generate and persist an insight for one activity. Leaves
    /// `entry.insightText` nil on any failure — picked up by the next
    /// `flushPending` call on foreground.
    func generate(for entry: ActivityLog, context: ModelContext) async {
        guard let response = try? await client.generateInsight(InsightPayload(from: entry)) else { return }
        entry.insightText = response.text
        try? context.save()
    }

    /// Retry every completed activity still missing an insight.
    func flushPending(context: ModelContext, limit: Int = 10) async {
        for entry in Self.pendingActivities(context: context, limit: limit) {
            await generate(for: entry, context: context)
        }
    }

    /// Completed activities still missing an insight, most recent first,
    /// capped to bound the retry burst after a long offline period.
    static func pendingActivities(context: ModelContext, limit: Int = 10) -> [ActivityLog] {
        var descriptor = FetchDescriptor<ActivityLog>(
            predicate: #Predicate { $0.endedAt != nil && $0.insightText == nil },
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }
}
