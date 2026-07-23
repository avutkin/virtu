import XCTest
import SwiftData
@testable import Pulsar

final class InsightGeneratorTests: XCTestCase {

    private func makeContext() -> ModelContext {
        let schema = Schema([ActivityLog.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [config])
        return ModelContext(container)
    }

    private struct StubError: Error {}

    private final class FakeClient: InsightAPIClient {
        let result: Result<InsightResponse, Error>
        init(result: Result<InsightResponse, Error>) { self.result = result }
        func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
            try result.get()
        }
        func generateLiveStateInsight(_ payload: LiveStateInsightPayload) async throws -> InsightResponse {
            try result.get()
        }
    }

    @MainActor
    func testGenerateSetsInsightTextOnSuccess() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Nice recovery."))))
        await generator.generate(for: entry, context: context)

        XCTAssertEqual(entry.insightText, "Nice recovery.")
    }

    @MainActor
    func testGenerateLeavesInsightTextNilOnFailure() async {
        let context = makeContext()
        let entry = ActivityLog(activityType: "Breathwork", startedAt: .now, endedAt: .now, isManual: true)
        context.insert(entry)

        let generator = InsightGenerator(client: FakeClient(result: .failure(StubError())))
        await generator.generate(for: entry, context: context)

        XCTAssertNil(entry.insightText)
    }

    @MainActor
    func testFlushPendingGeneratesForAllPendingActivities() async {
        let context = makeContext()
        let a = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        let b = ActivityLog(activityType: "Walk",
                             startedAt: .now.addingTimeInterval(60),
                             endedAt: .now.addingTimeInterval(90), isManual: true)
        context.insert(a)
        context.insert(b)

        let generator = InsightGenerator(client: FakeClient(result: .success(InsightResponse(text: "Solid."))))
        await generator.flushPending(context: context)

        XCTAssertEqual(a.insightText, "Solid.")
        XCTAssertEqual(b.insightText, "Solid.")
    }

    @MainActor
    func testPendingActivitiesFiltersEndedAndMissingInsight() {
        let context = makeContext()

        let notEnded = ActivityLog(activityType: "Walk", startedAt: .now, isManual: false)
        let alreadyInsighted = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)
        alreadyInsighted.insightText = "Already have one."
        let pending = ActivityLog(activityType: "Walk", startedAt: .now, endedAt: .now, isManual: true)

        context.insert(notEnded)
        context.insert(alreadyInsighted)
        context.insert(pending)

        let result = InsightGenerator.pendingActivities(context: context)

        XCTAssertEqual(result.map(\.id), [pending.id])
    }

    @MainActor
    func testPendingActivitiesOrdersMostRecentFirstAndCaps() {
        let context = makeContext()
        let base = Date()
        var entries: [ActivityLog] = []
        for i in 0..<12 {
            let entry = ActivityLog(activityType: "Walk",
                                     startedAt: base.addingTimeInterval(TimeInterval(i) * 60),
                                     endedAt: base.addingTimeInterval(TimeInterval(i) * 60 + 30),
                                     isManual: true)
            context.insert(entry)
            entries.append(entry)
        }

        let result = InsightGenerator.pendingActivities(context: context, limit: 10)

        XCTAssertEqual(result.count, 10)
        XCTAssertEqual(result.first?.id, entries.last?.id)
    }
}
