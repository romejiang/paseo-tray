import Foundation

struct PaseoConnectionStatus: Equatable {
    enum Phase: String {
        case offline
        case connecting
        case connected
        case authRequired
        case unsupported
    }

    var phase: Phase
    var detail: String
    var serverVersion: String?
    var subscriptionError: String?
    var attempt: Int

    init(
        phase: Phase = .offline,
        detail: String = "",
        serverVersion: String? = nil,
        subscriptionError: String? = nil,
        attempt: Int = 0
    ) {
        self.phase = phase
        self.detail = detail
        self.serverVersion = serverVersion
        self.subscriptionError = subscriptionError
        self.attempt = attempt
    }
}

enum PaseoClientEvent {
    case status(PaseoConnectionStatus)
    case snapshot(entries: [[String: Any]], hasMore: Bool, serverId: String)
    case agentUpdate([String: Any])
    case attention([String: Any])
}

protocol PaseoClientDelegate: AnyObject {
    func paseoClient(_ client: PaseoClient, event: PaseoClientEvent)
}

/// Reads the daemon endpoint from a Paseo home. The token is deliberately not
/// printable or loggable; it is only placed in the hello frame.
private struct DiscoveryResult {
    let listen: String
    let serverId: String?
    let token: String?
}

private enum DiscoveryError: LocalizedError {
    case missing(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .missing(let message): return message
        case .unsupported(let message): return message
        }
    }
}

final class PaseoClient {
    weak var delegate: PaseoClientDelegate?

    let homeURL: URL
    private let clientId: String
    private let appVersion: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var generation = 0
    private var started = false
    private var status = PaseoConnectionStatus()
    private var reconnectAttempt = 0
    private var reconnectWorkItem: DispatchWorkItem?
    private var connectTimeoutWorkItem: DispatchWorkItem?
    private var agentsTimeoutWorkItem: DispatchWorkItem?
    private var eventsTimeoutWorkItem: DispatchWorkItem?
    private var pingTimer: Timer?
    private var watchdogTimer: Timer?
    private var lastMessageAt = Date()
    private var serverId: String?
    private var agentsRequestId: String?
    private var eventsRequestId: String?
    private var agentsAck = false
    private var eventsAck = false
    private var agentsRetryCount = 0
    private var eventsRetryCount = 0
    private let subscriptionTimeout: TimeInterval = 8
    private let maxSubscriptionRetries = 1

    init(delegate: PaseoClientDelegate, homeURL: URL? = nil) {
        self.delegate = delegate
        if let homeURL {
            self.homeURL = homeURL
        } else {
            let raw = ProcessInfo.processInfo.environment["PASEO_HOME"] ?? "~/.paseo"
            self.homeURL = URL(
                fileURLWithPath: (raw as NSString).expandingTildeInPath,
                isDirectory: true
            )
        }

        let key = "PaseoTrayClientId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            self.clientId = existing
        } else {
            let created = "paseo-tray-\(UUID().uuidString.lowercased())"
            UserDefaults.standard.set(created, forKey: key)
            self.clientId = created
        }
        self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    func start() {
        guard !started else { return }
        started = true
        connect(resetAttempts: true)
    }

    func stop() {
        started = false
        cancelReconnect()
        cancelConnection()
    }

    func reconnectNow() {
        guard started else { return }
        reconnectAttempt = 0
        cancelReconnect()
        connect(resetAttempts: true)
    }

    // MARK: - Connection lifecycle

    private func connect(resetAttempts: Bool) {
        guard started else { return }
        cancelReconnect()
        cancelConnection()
        if resetAttempts { reconnectAttempt = 0 }

        let discovery: DiscoveryResult
        do {
            discovery = try discover()
        } catch {
            let message = error.localizedDescription
            let unsupported = (error as? DiscoveryError).map {
                if case .unsupported = $0 { return true }
                return false
            } ?? false
            status = PaseoConnectionStatus(
                phase: unsupported ? .unsupported : .offline,
                detail: message
            )
            publishStatus()
            scheduleReconnect(delay: unsupported ? 30 : 2)
            return
        }

        serverId = discovery.serverId
        guard let url = URL(string: "ws://\(discovery.listen)/ws") else {
            status = PaseoConnectionStatus(phase: .unsupported, detail: "daemon 地址无法转换为 WebSocket URL")
            publishStatus()
            scheduleReconnect(delay: 30)
            return
        }

        status = PaseoConnectionStatus(phase: .connecting, detail: discovery.listen)
        publishStatus()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 0
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        self.session = session

        let task = session.webSocketTask(with: url)
        self.task = task
        generation += 1
        let currentGeneration = generation
        lastMessageAt = Date()

        task.resume()
        receiveNext(generation: currentGeneration)
        sendHello(token: discovery.token)
        startTimers()
        scheduleConnectTimeout(generation: currentGeneration)
    }

    private func cancelConnection() {
        generation += 1
        connectTimeoutWorkItem?.cancel()
        connectTimeoutWorkItem = nil
        agentsTimeoutWorkItem?.cancel()
        agentsTimeoutWorkItem = nil
        eventsTimeoutWorkItem?.cancel()
        eventsTimeoutWorkItem = nil
        pingTimer?.invalidate()
        pingTimer = nil
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func cancelReconnect() {
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
    }

    private func scheduleReconnect(delay: TimeInterval) {
        guard started else { return }
        cancelReconnect()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.connect(resetAttempts: false)
        }
        reconnectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func nextBackoff() -> TimeInterval {
        let steps: [TimeInterval] = [1, 2, 5, 10, 30]
        let index = min(reconnectAttempt, steps.count - 1)
        reconnectAttempt += 1
        return steps[index]
    }

    private func scheduleConnectTimeout(generation expected: Int) {
        connectTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expected, self.status.phase == .connecting else {
                return
            }
            self.handleDisconnect("连接超时（10 秒）")
        }
        connectTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: item)
    }

    private func startTimers() {
        pingTimer?.invalidate()
        let ping = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.task != nil else { return }
            self.sendRaw(["type": "ping"])
        }
        pingTimer = ping
        RunLoop.main.add(ping, forMode: .common)

        watchdogTimer?.invalidate()
        let watchdog = Timer(timeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.task != nil else { return }
            if Date().timeIntervalSince(self.lastMessageAt) > 90 {
                self.handleDisconnect("90 秒无消息")
            }
        }
        watchdogTimer = watchdog
        RunLoop.main.add(watchdog, forMode: .common)
    }

    private func handleDisconnect(_ detail: String) {
        guard started else { return }
        cancelConnection()
        status = PaseoConnectionStatus(phase: .offline, detail: detail)
        publishStatus()
        scheduleReconnect(delay: nextBackoff())
    }

    // MARK: - Daemon discovery

    private func discover() throws -> DiscoveryResult {
        let pidURL = homeURL.appendingPathComponent("paseo.pid")
        var listen: String?
        var serverId: String?

        if let data = try? Data(contentsOf: pidURL),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let raw = object["listen"] as? String, !raw.isEmpty {
                listen = raw
            }
            serverId = object["serverId"] as? String
        }

        if listen == nil {
            let configURL = homeURL.appendingPathComponent("config.json")
            if let data = try? Data(contentsOf: configURL),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let daemon = object["daemon"] as? [String: Any],
               let raw = daemon["listen"] as? String,
               !raw.isEmpty {
                listen = raw
            }
        }

        guard let listen else {
            throw DiscoveryError.missing("未找到 \(pidURL.path) 或 config.json 中的 daemon.listen")
        }
        let trimmed = listen.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isHostPort(trimmed) else {
            throw DiscoveryError.unsupported("暂不支持该 daemon listen：\(trimmed)")
        }

        let tokenURL = homeURL.appendingPathComponent("local-credential")
        let token = (try? String(contentsOf: tokenURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DiscoveryResult(
            listen: trimmed,
            serverId: serverId,
            token: token?.isEmpty == false ? token : nil
        )
    }

    static func isHostPort(_ value: String) -> Bool {
        if value.hasPrefix("/") || value.hasPrefix("unix://") || value.hasPrefix("pipe://") {
            return false
        }
        if value.hasPrefix("\\\\") { return false }
        guard let colon = value.lastIndex(of: ":") else { return false }
        let host = String(value[..<colon])
        let portText = String(value[value.index(after: colon)...])
        guard !host.isEmpty, let port = Int(portText), port > 0, port <= 65535 else {
            return false
        }
        guard !host.contains("/") else { return false }
        guard host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return false }
        return true
    }

    // MARK: - Sending

    private func sendHello(token: String?) {
        var hello: [String: Any] = [
            "type": "hello",
            "clientId": clientId,
            "clientType": "cli",
            "protocolVersion": 1,
            "appVersion": appVersion,
            "capabilities": [
                "owned_subscriptions": true,
                "explicit_event_subscriptions": true,
                "hello_rejection": true,
            ],
        ]
        if let token, !token.isEmpty {
            hello["auth"] = ["kind": "localCredential", "token": token]
        }
        sendRaw(hello)
    }

    private func sendSession(_ message: [String: Any]) {
        sendRaw(["type": "session", "message": message])
    }

    private func sendRaw(_ object: [String: Any]) {
        guard let task else { return }
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            trayLog("无法序列化 WebSocket 消息")
            return
        }
        let currentGeneration = generation
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self, self.generation == currentGeneration else { return }
                self.handleDisconnect("发送失败：\(error.localizedDescription)")
            }
        }
    }

    private func requestAgentsSubscription() {
        agentsAck = false
        let requestId = "agents-\(UUID().uuidString.prefix(8))"
        agentsRequestId = requestId
        sendSession([
            "type": "fetch_agents_request",
            "requestId": requestId,
            "scope": "active",
            "filter": [
                "includeArchived": false,
                "includeBackground": false,
            ],
            "page": ["limit": 200],
            "subscribe": [:],
        ])
        scheduleAgentsTimeout(requestId: requestId)
    }

    private func requestEventsSubscription() {
        eventsAck = false
        let requestId = "events-\(UUID().uuidString.prefix(8))"
        eventsRequestId = requestId
        sendSession([
            "type": "session.events.set_subscription.request",
            "requestId": requestId,
            "events": ["agent_attention_required"],
            "notifications": true,
        ])
        scheduleEventsTimeout(requestId: requestId)
    }

    private func scheduleAgentsTimeout(requestId: String) {
        agentsTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.status.phase == .connected,
                  self.agentsRequestId == requestId, !self.agentsAck else { return }
            self.retryAgentsSubscription(error: "订阅超时")
        }
        agentsTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + subscriptionTimeout, execute: item)
    }

    private func scheduleEventsTimeout(requestId: String) {
        eventsTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.status.phase == .connected,
                  self.eventsRequestId == requestId, !self.eventsAck else { return }
            self.retryEventsSubscription(error: "事件订阅超时")
        }
        eventsTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + subscriptionTimeout, execute: item)
    }

    private func retryAgentsSubscription(error: String) {
        agentsRetryCount += 1
        guard agentsRetryCount <= maxSubscriptionRetries else {
            handleDisconnect("订阅失败：\(error)")
            return
        }
        status.subscriptionError = "\(error)，正在重试"
        publishStatus()
        requestAgentsSubscription()
    }

    private func retryEventsSubscription(error: String) {
        eventsRetryCount += 1
        guard eventsRetryCount <= maxSubscriptionRetries else {
            handleDisconnect("事件订阅失败：\(error)")
            return
        }
        status.subscriptionError = "\(error)，正在重试"
        publishStatus()
        requestEventsSubscription()
    }

    private func markAgentsAck() {
        agentsAck = true
        agentsRetryCount = 0
        agentsTimeoutWorkItem?.cancel()
        agentsTimeoutWorkItem = nil
        if eventsAck {
            status.subscriptionError = nil
        }
        resetReconnectBackoffIfSubscribed()
        publishStatus()
    }

    private func markEventsAck() {
        eventsAck = true
        eventsRetryCount = 0
        eventsTimeoutWorkItem?.cancel()
        eventsTimeoutWorkItem = nil
        if agentsAck {
            status.subscriptionError = nil
        }
        resetReconnectBackoffIfSubscribed()
        publishStatus()
    }

    /// Only a fully acknowledged subscription proves the connection is
    /// healthy enough to reset the reconnect backoff. Resetting on
    /// `server_info` alone makes a daemon that accepts the socket but rejects
    /// the subscriptions reconnect forever at one second.
    private func resetReconnectBackoffIfSubscribed() {
        guard agentsAck && eventsAck else { return }
        reconnectAttempt = 0
    }

    // MARK: - Receiving

    private func receiveNext(generation expected: Int) {
        guard let task else { return }
        task.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.started, self.generation == expected else { return }
                switch result {
                case .failure(let error):
                    self.handleDisconnect("连接断开：\(error.localizedDescription)")
                case .success(let message):
                    self.lastMessageAt = Date()
                    switch message {
                    case .string(let text):
                        self.handleFrame(text)
                    case .data(let data):
                        if let text = String(data: data, encoding: .utf8) {
                            self.handleFrame(text)
                        }
                    @unknown default:
                        break
                    }
                    if self.generation == expected, self.task != nil {
                        self.receiveNext(generation: expected)
                    }
                }
            }
        }
    }

    private func handleFrame(_ text: String) {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return
        }
        switch type {
        case "session":
            if let message = object["message"] as? [String: Any] {
                handleSession(message)
            }
        case "status":
            if let payload = object["payload"] as? [String: Any] {
                handleStatus(payload)
            }
        case "hello.rejected":
            handleHelloRejected(object)
        case "pong":
            break
        default:
            break
        }
    }

    private func handleSession(_ message: [String: Any]) {
        guard let type = message["type"] as? String else { return }
        switch type {
        case "status":
            if let payload = message["payload"] as? [String: Any] {
                handleStatus(payload)
            }
        case "fetch_agents_response":
            handleFetchAgents(message)
        case "agent_update":
            if let payload = message["payload"] as? [String: Any] {
                delegate?.paseoClient(self, event: .agentUpdate(payload))
            }
        case "agent_attention_required":
            markEventsAck()
            if let payload = message["payload"] as? [String: Any] {
                delegate?.paseoClient(self, event: .attention(payload))
            }
        case "session.events.set_subscription.response":
            if let payload = message["payload"] as? [String: Any],
               let requestId = payload["requestId"] as? String,
               let current = eventsRequestId,
               requestId != current {
                break
            }
            markEventsAck()
        case "rpc_error":
            handleRpcError(message)
        default:
            break
        }
    }

    private func handleRpcError(_ message: [String: Any]) {
        guard let payload = message["payload"] as? [String: Any],
              let requestId = payload["requestId"] as? String else { return }
        let error = payload["error"] as? String ?? "请求失败"
        if requestId == agentsRequestId {
            agentsTimeoutWorkItem?.cancel()
            agentsTimeoutWorkItem = nil
            agentsAck = false
            status.subscriptionError = error
            publishStatus()
            retryAgentsSubscription(error: error)
            return
        }
        if requestId == eventsRequestId {
            eventsTimeoutWorkItem?.cancel()
            eventsTimeoutWorkItem = nil
            eventsAck = false
            status.subscriptionError = error
            publishStatus()
            retryEventsSubscription(error: error)
        }
    }

    private func handleStatus(_ payload: [String: Any]) {
        guard payload["status"] as? String == "server_info" else { return }
        if let id = payload["serverId"] as? String, !id.isEmpty {
            serverId = id
        }
        agentsAck = false
        eventsAck = false
        agentsRetryCount = 0
        eventsRetryCount = 0
        agentsRequestId = nil
        eventsRequestId = nil
        status = PaseoConnectionStatus(
            phase: .connected,
            detail: "已连接",
            serverVersion: payload["version"] as? String,
            subscriptionError: nil
        )
        publishStatus()
        requestAgentsSubscription()
        requestEventsSubscription()
    }

    private func handleFetchAgents(_ message: [String: Any]) {
        guard let payload = message["payload"] as? [String: Any] else {
            retryAgentsSubscription(error: "订阅返回格式不正确")
            return
        }
        if let requestId = payload["requestId"] as? String,
           let current = agentsRequestId,
           requestId != current {
            return
        }
        guard let entries = payload["entries"] as? [[String: Any]] else {
            agentsTimeoutWorkItem?.cancel()
            agentsTimeoutWorkItem = nil
            agentsAck = false
            status.subscriptionError = "订阅返回格式不正确"
            publishStatus()
            retryAgentsSubscription(error: "订阅返回格式不正确")
            return
        }
        markAgentsAck()
        let pageInfo = payload["pageInfo"] as? [String: Any]
        let hasMore = pageInfo?["hasMore"] as? Bool ?? false
        let id = serverId ?? ""
        delegate?.paseoClient(
            self,
            event: .snapshot(entries: entries, hasMore: hasMore, serverId: id)
        )
    }

    private func handleHelloRejected(_ object: [String: Any]) {
        let reason = object["reason"] as? String ?? "unknown"
        cancelConnection()
        switch reason {
        case "password_required", "incorrect_password":
            status = PaseoConnectionStatus(
                phase: .authRequired,
                detail: "需要密码。请在 Paseo 中打开本机 daemon 后重试。"
            )
            publishStatus()
            scheduleReconnect(delay: 30)
        case "incompatible_protocol":
            status = PaseoConnectionStatus(
                phase: .unsupported,
                detail: "daemon 与托盘的协议版本不兼容"
            )
            publishStatus()
            scheduleReconnect(delay: 30)
        default:
            status = PaseoConnectionStatus(phase: .offline, detail: "连接被拒绝：\(reason)")
            publishStatus()
            scheduleReconnect(delay: nextBackoff())
        }
    }

    private func publishStatus() {
        status.attempt = reconnectAttempt
        delegate?.paseoClient(self, event: .status(status))
    }
}
