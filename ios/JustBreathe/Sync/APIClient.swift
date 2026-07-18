import Foundation

// MARK: - Wire types (Codable)

struct SessionPayload: Codable {
    let id:           String
    let startedAt:    String   // ISO8601
    let endedAt:      String?
    let avgRSAms:     Float?
    let avgCoherence: Float?
    let notes:        String?
    let samples:      [SamplePayload]
}

struct SamplePayload: Codable {
    let ts:         String   // ISO8601
    let meanBPM:    Float?
    let rmssd:      Float?
    let sdnn:       Float?
    let pnn50:      Float?
    let lfHF:       Float?
    let rsaMs:      Float?
    let rsaIdx:     Float?
    let coherence:  Float?
    let cbi:        Float?
    let breathBPM:  Float?
}

struct TickPayload: Codable {
    let userId:   String
    let ts:       String
    let meanBPM:  Float?
    let rmssd:    Float?
    let rsaMs:    Float?
    let coherence: Float?
    let cbi:      Float?
    let breathBPM: Float?
}

struct InsightPayload: Codable {
    let activityType:    String
    let activitySubtype: String?
    let durationMin:     Int?
    let beforeHR: Float?;    let duringHR: Float?;    let afterHR: Float?
    let beforeRSA: Float?;   let duringRSA: Float?;   let afterRSA: Float?
    let beforeSDNN: Float?;  let duringSDNN: Float?;  let afterSDNN: Float?
    let beforeLFHF: Float?;  let duringLFHF: Float?;  let afterLFHF: Float?

    enum CodingKeys: String, CodingKey {
        case activityType    = "activity_type"
        case activitySubtype = "activity_subtype"
        case durationMin     = "duration_min"
        case beforeHR = "before_hr"; case duringHR = "during_hr"; case afterHR = "after_hr"
        case beforeRSA = "before_rsa"; case duringRSA = "during_rsa"; case afterRSA = "after_rsa"
        case beforeSDNN = "before_sdnn"; case duringSDNN = "during_sdnn"; case afterSDNN = "after_sdnn"
        case beforeLFHF = "before_lf_hf"; case duringLFHF = "during_lf_hf"; case afterLFHF = "after_lf_hf"
    }
}

struct InsightResponse: Codable {
    let text: String
}

struct ServerSession: Codable {
    let id:           String
    let startedAt:    String
    let endedAt:      String?
    let avgRSAms:     Float?
    let avgCoherence: Float?
}

struct UploadResponse: Codable {
    let id: String
}

// MARK: - APIClient

struct APIClient {
    let baseURL: URL
    private let session = URLSession.shared
    private let iso = ISO8601DateFormatter()

    // MARK: Sessions

    func uploadSession(_ payload: SessionPayload, userID: String) async throws -> UploadResponse {
        var req = request(path: "/sessions", method: "POST")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(UploadResponse.self, from: data)
    }

    func fetchSessions(userID: String) async throws -> [ServerSession] {
        var req = request(path: "/sessions", method: "GET")
        req.addValue(userID, forHTTPHeaderField: "X-User-ID")
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode([ServerSession].self, from: data)
    }

    // MARK: Insights

    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse {
        var req = request(path: "/insights", method: "POST")
        req.httpBody = try JSONEncoder().encode(payload)
        let (data, _) = try await session.data(for: req)
        return try JSONDecoder().decode(InsightResponse.self, from: data)
    }

    // MARK: Helpers

    private func request(path: String, method: String) -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.addValue("application/json", forHTTPHeaderField: "Content-Type")
        r.timeoutInterval = 15
        return r
    }
}

// MARK: - InsightAPIClient

/// Narrow protocol over `APIClient.generateInsight` so `InsightGenerator`
/// can be tested with a fake instead of a real network call.
protocol InsightAPIClient {
    func generateInsight(_ payload: InsightPayload) async throws -> InsightResponse
}

extension APIClient: InsightAPIClient {}

// MARK: - Payload builders

extension SessionPayload {
    init(from session: HRVSession) {
        let iso = ISO8601DateFormatter()
        self.id          = session.id.uuidString
        self.startedAt   = iso.string(from: session.startedAt)
        self.endedAt     = session.endedAt.map { iso.string(from: $0) }
        self.avgRSAms    = session.avgRSAms
        self.avgCoherence = session.avgCoherence
        self.notes       = session.notes
        self.samples     = session.samples.map { SamplePayload(from: $0) }
    }
}

extension SamplePayload {
    init(from s: HRVSample) {
        let iso = ISO8601DateFormatter()
        self.ts        = iso.string(from: s.timestamp)
        self.meanBPM   = s.meanBPM
        self.rmssd     = s.rmssd
        self.sdnn      = s.sdnn
        self.pnn50     = s.pnn50
        self.lfHF      = s.lfHF
        self.rsaMs     = s.rsaMs
        self.rsaIdx    = s.rsaIdx
        self.coherence = s.coherence
        self.cbi       = s.cbi
        self.breathBPM = s.breathBPM
    }
}

extension TickPayload {
    init(from tick: MetricsTick, userID: String) {
        let iso = ISO8601DateFormatter()
        self.userId    = userID
        self.ts        = iso.string(from: tick.timestamp)
        self.meanBPM   = tick.meanBPM
        self.rmssd     = tick.rmssd
        self.rsaMs     = tick.rsaMs
        self.coherence = tick.coherenceScore
        self.cbi       = tick.cbi
        self.breathBPM = tick.breathBPM
    }
}

extension InsightPayload {
    init(from entry: ActivityLog) {
        self.activityType    = entry.activityType
        self.activitySubtype = entry.activitySubtype
        self.durationMin     = entry.duration.map { Int($0 / 60) }
        self.beforeHR   = entry.beforeHR;   self.duringHR   = entry.duringHR;   self.afterHR   = entry.afterHR
        self.beforeRSA  = entry.beforeRSA;  self.duringRSA  = entry.duringRSA;  self.afterRSA  = entry.afterRSA
        self.beforeSDNN = entry.beforeSDNN; self.duringSDNN = entry.duringSDNN; self.afterSDNN = entry.afterSDNN
        self.beforeLFHF = entry.beforeLFHF; self.duringLFHF = entry.duringLFHF; self.afterLFHF = entry.afterLFHF
    }
}
