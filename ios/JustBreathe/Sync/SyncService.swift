import Foundation

// MARK: - SyncService

/// Handles live tick streaming (WebSocket) and session archival (REST).
/// Auto-reconnects WebSocket with exponential backoff.
@Observable
final class SyncService {

    private(set) var isConnected = false
    var serverURL: URL

    private var wsTask:    URLSessionWebSocketTask?
    private var reconnectDelay: TimeInterval = 2
    private let maxDelay:       TimeInterval = 60
    private var userID:         String?
    private var streamActive    = false

    let client: APIClient
    private let urlSession = URLSession(configuration: .default)

    init(serverURL: URL) {
        self.serverURL = serverURL
        self.client    = APIClient(baseURL: serverURL)
    }

    // MARK: WebSocket — live streaming

    func beginSession(userID: String) {
        self.userID   = userID
        streamActive  = true
        reconnectDelay = 2
        connect(userID: userID)
    }

    func endStream() {
        streamActive = false
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask    = nil
        isConnected = false
    }

    func sendTick(_ tick: MetricsTick, userID: String) {
        guard isConnected, let ws = wsTask else { return }
        let payload = TickPayload(from: tick, userID: userID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        ws.send(.data(data)) { _ in }   // fire-and-forget
    }

    // MARK: REST — session archive

    func uploadSession(_ session: HRVSession) async throws {
        let payload = SessionPayload(from: session)
        _ = try await client.uploadSession(payload, userID: userID ?? "anonymous")
    }

    // MARK: Private — WebSocket lifecycle

    private func connect(userID: String) {
        let wsURL = serverURL
            .deletingPathExtension()
            .appendingPathComponent("stream")
            .appendingPathComponent(userID)
        var components = URLComponents(url: wsURL, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { return }

        wsTask = urlSession.webSocketTask(with: url)
        wsTask?.resume()
        isConnected = true
        reconnectDelay = 2
        listen()
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.listen()   // keep reading
            case .failure:
                self.isConnected = false
                self.scheduleReconnect()
            }
        }
    }

    private func scheduleReconnect() {
        guard streamActive, let uid = userID else { return }
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, maxDelay)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            self?.connect(userID: uid)
        }
    }
}
