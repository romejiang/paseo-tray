import AppKit
import Darwin
import Foundation

/// Headless diagnostics used by the acceptance harness:
/// `--selftest` prints one snapshot and exits; `--watch-json` streams every
/// status, snapshot, update, attention event, and config change as JSON lines.
final class Diagnostics: NSObject, PaseoClientDelegate {
    private let watch: Bool
    private let store = AgentStore()
    private let configStore = TrayConfigStore()
    private let announceGate = AttentionGate()
    private var config = TrayConfig.defaults
    private var client: PaseoClient?
    private var serverId: String?
    private var finished = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(watch: Bool) {
        self.watch = watch
        super.init()
    }

    func start() {
        let loaded = configStore.load()
        config = loaded.config
        configStore.startWatching { [weak self] config, error in
            guard let self else { return }
            self.config = config
            var payload: [String: Any] = [
                "event": "config",
                "configPath": self.configStore.displayPath,
                "config": config.jsonObject,
            ]
            if let error { payload["error"] = error }
            self.emit(payload)
        }

        emit([
            "event": "start",
            "watch": watch,
            "configPath": configStore.displayPath,
            "paseoHome": (ProcessInfo.processInfo.environment["PASEO_HOME"] ?? "~/.paseo"),
            "configError": loaded.error ?? NSNull(),
        ])

        if !watch {
            let item = DispatchWorkItem { [weak self] in
                self?.finish(code: 1, reason: "timeout")
            }
            timeoutWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
        }

        let client = PaseoClient(delegate: self)
        self.client = client
        client.start()
    }

    func paseoClient(_ client: PaseoClient, event: PaseoClientEvent) {
        switch event {
        case .status(let status):
            var payload: [String: Any] = [
                "event": "status",
                "phase": status.phase.rawValue,
                "detail": status.detail,
                "attempt": status.attempt,
            ]
            if let version = status.serverVersion { payload["serverVersion"] = version }
            if let subscriptionError = status.subscriptionError {
                payload["subscriptionError"] = subscriptionError
            }
            emit(payload)
        case .snapshot(let entries, let hasMore, let serverId):
            store.replace(entries: entries, hasMore: hasMore)
            self.serverId = serverId
            emit(stateEvent("snapshot", extra: [
                "serverId": serverId,
                "hasMore": hasMore,
            ]))
            if !watch {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.finish(code: 0, reason: "snapshot")
                }
            }
        case .agentUpdate(let payload):
            store.apply(update: payload)
            emit(stateEvent("update", extra: ["payloadKind": payload["kind"] as? String ?? "unknown"]))
        case .attention(let payload):
            store.applyAttention(payload: payload)
            let agentId = payload["agentId"] as? String ?? ""
            let reason = payload["reason"] as? String ?? "unknown"
            let timestamp = payload["timestamp"] as? String ?? ""
            let timestampDate = TrayDate.parse(timestamp) ?? Date()
            let enabled = NotificationPolicy.shouldNotify(reason: reason, config: config)
            let paseoFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "sh.paseo.desktop"
            emit(stateEvent("attention", extra: [
                "agentId": agentId,
                "reason": reason,
                "timestamp": timestamp,
                "notifyEnabled": enabled,
                "paseoFrontmost": paseoFrontmost,
                "wouldNotify": enabled && !paseoFrontmost,
            ]))
            let isNew = announceGate.accept(
                agentId: agentId,
                reason: reason,
                timestamp: timestampDate
            )
            if isNew {
                emit(stateEvent("announce", extra: [
                    "agentId": agentId,
                    "reason": reason,
                    "timestamp": timestamp,
                    "flashed": NotificationPolicy.shouldAnnounce(
                        isNew: isNew,
                        paseoFrontmost: paseoFrontmost
                    ),
                    "suppressedFrontmost": paseoFrontmost,
                ]))
            }
        }
    }

    private func stateEvent(_ name: String, extra: [String: Any]) -> [String: Any] {
        let visible = store.visible(config: config)
        let sections = store.sections(config: config)
        var payload: [String: Any] = [
            "event": name,
            "counts": store.counts(config: config).jsonObject,
            "order": [
                "needsInput": sections.needsInput.map(\.id),
                "failed": sections.failed.map(\.id),
                "running": sections.running.map(\.id),
                "attention": sections.attention.map(\.id),
            ],
            "agents": visible.map { agent in
                var item: [String: Any] = [
                    "id": agent.id,
                    "title": agent.displayTitle,
                    "provider": agent.provider,
                    "status": agent.status,
                    "bucket": agent.bucket.rawValue,
                    "updatedAt": Int(agent.updatedAt.timeIntervalSince1970),
                ]
                if let reason = agent.attentionReason { item["attentionReason"] = reason }
                if let timestamp = agent.attentionTimestamp {
                    item["attentionTimestamp"] = Int(timestamp.timeIntervalSince1970)
                }
                return item
            },
            "hasMore": store.hasMore,
        ]
        for (key, value) in extra {
            payload[key] = value
        }
        if let serverId { payload["serverId"] = serverId }
        return payload
    }

    private func emit(_ payload: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(payload),
              let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let line = String(data: data, encoding: .utf8) else {
            return
        }
        print(line)
        fflush(stdout)
    }

    private func finish(code: Int32, reason: String) {
        guard !finished else { return }
        finished = true
        timeoutWorkItem?.cancel()
        emit(["event": "done", "reason": reason])
        client?.stop()
        configStore.stopWatching()
        exit(code)
    }
}
