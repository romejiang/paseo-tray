import Foundation

enum TrayDate {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: Any?) -> Date? {
        guard let string = value as? String, !string.isEmpty else { return nil }
        return fractional.date(from: string) ?? plain.date(from: string)
    }
}

enum AgentBucket: String {
    case needsInput = "needs_input"
    case failed
    case running
    case attention
    case done

    var sectionTitle: String {
        switch self {
        case .needsInput: return "需要你处理"
        case .failed: return "失败"
        case .running: return "运行中"
        case .attention: return "已完成"
        case .done: return "已完成"
        }
    }

    var menuPrefix: String {
        switch self {
        case .needsInput: return "○"
        case .failed: return "✕"
        case .running: return "●"
        case .attention: return "✓"
        case .done: return "✓"
        }
    }
}

struct Agent {
    let id: String
    var title: String?
    var provider: String
    var status: String
    var requiresAttention: Bool
    var attentionReason: String?
    var attentionTimestamp: Date?
    var pendingPermissionCount: Int
    var labels: [String: String]
    var background: Bool
    var internalAgent: Bool
    var archivedAt: Date?
    var activeTurnStartedAt: Date?
    var updatedAt: Date
    var createdAt: Date
    var cwd: String?
    var projectName: String?
    var workspaceName: String?

    init?(dictionary: [String: Any], project: [String: Any]? = nil) {
        guard let id = dictionary["id"] as? String, !id.isEmpty else { return nil }
        self.id = id
        let rawTitle = (dictionary["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = rawTitle?.isEmpty == false ? rawTitle : nil
        self.provider = dictionary["provider"] as? String ?? "unknown"
        self.status = dictionary["status"] as? String ?? "idle"
        self.requiresAttention = dictionary["requiresAttention"] as? Bool ?? false
        self.attentionReason = dictionary["attentionReason"] as? String
        self.attentionTimestamp = TrayDate.parse(dictionary["attentionTimestamp"])
        self.pendingPermissionCount = (dictionary["pendingPermissions"] as? [Any])?.count ?? 0
        if let labels = dictionary["labels"] as? [String: Any] {
            self.labels = labels.compactMapValues { $0 as? String }
        } else {
            self.labels = [:]
        }
        self.background = dictionary["background"] as? Bool ?? false
        self.internalAgent = dictionary["internal"] as? Bool ?? false
        self.archivedAt = TrayDate.parse(dictionary["archivedAt"])
        if let turn = dictionary["activeTurn"] as? [String: Any] {
            self.activeTurnStartedAt = TrayDate.parse(turn["startedAt"])
        } else {
            self.activeTurnStartedAt = nil
        }
        let updated = TrayDate.parse(dictionary["updatedAt"]) ?? Date()
        self.updatedAt = updated
        self.createdAt = TrayDate.parse(dictionary["createdAt"]) ?? updated
        self.cwd = dictionary["cwd"] as? String
        self.projectName = project?["projectName"] as? String
        self.workspaceName = project?["workspaceName"] as? String
    }

    var shortId: String {
        String(id.prefix(8))
    }

    var displayTitle: String {
        title ?? shortId
    }

    var isSubagent: Bool {
        !(labels["paseo.parent-agent-id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var bucket: AgentBucket {
        if pendingPermissionCount > 0 || attentionReason == "permission" {
            return .needsInput
        }
        if status == "error" || attentionReason == "error" {
            return .failed
        }
        if status == "running" {
            return .running
        }
        if requiresAttention {
            return .attention
        }
        return .done
    }

    var menuTimestamp: Date {
        switch bucket {
        case .running:
            return activeTurnStartedAt ?? updatedAt
        case .needsInput, .failed, .attention:
            return attentionTimestamp ?? updatedAt
        case .done:
            return updatedAt
        }
    }

    mutating func markAttention(reason: String, timestamp: Date?) {
        requiresAttention = true
        attentionReason = reason
        attentionTimestamp = timestamp ?? Date()
        switch reason {
        case "finished", "permission":
            // The attention event is authoritative for completion; the
            // follow-up agent_update may still be in flight.
            if status == "running" { status = "idle" }
        case "error":
            status = "error"
        default:
            break
        }
        if reason == "permission" && pendingPermissionCount == 0 {
            pendingPermissionCount = 1
        }
    }
}

struct AgentCounts: Equatable {
    var running = 0
    var finished = 0
    var needsInput = 0
    var failed = 0

    var actionable: Int { needsInput + failed }
    var total: Int { running + finished + actionable }

    var jsonObject: [String: Any] {
        [
            "running": running,
            "finished": finished,
            "needsInput": needsInput,
            "failed": failed,
            "actionable": actionable,
            "total": total,
        ]
    }
}

struct AgentSections {
    var needsInput: [Agent] = []
    var failed: [Agent] = []
    var running: [Agent] = []
    var attention: [Agent] = []

    var isEmpty: Bool {
        needsInput.isEmpty && failed.isEmpty && running.isEmpty && attention.isEmpty
    }
}

final class AgentStore {
    private struct PendingAttention {
        let reason: String
        let timestamp: Date
        let receivedAt: Date
    }

    private static let pendingAttentionLimit = 100
    private static let pendingAttentionTTL: TimeInterval = 300

    private(set) var agents: [String: Agent] = [:]
    private(set) var hasMore = false
    private(set) var receivedSnapshot = false
    private var pendingAttention: [String: PendingAttention] = [:]

    var pendingAttentionCount: Int { pendingAttention.count }

    func replace(entries: [[String: Any]], hasMore: Bool) {
        var next: [String: Agent] = [:]
        for entry in entries {
            guard let dictionary = entry["agent"] as? [String: Any],
                  let agent = Agent(
                      dictionary: dictionary,
                      project: entry["project"] as? [String: Any]
                  ) else { continue }
            next[agent.id] = agent
        }
        prunePendingAttention()
        for id in Array(next.keys) {
            guard var agent = next[id] else { continue }
            mergePendingAttention(into: &agent)
            next[id] = agent
        }
        agents = next
        self.hasMore = hasMore
        receivedSnapshot = true
    }

    func clear() {
        agents = [:]
        pendingAttention = [:]
        hasMore = false
        receivedSnapshot = false
    }

    func apply(update payload: [String: Any]) {
        guard let kind = payload["kind"] as? String else { return }
        if kind == "remove" {
            if let agentId = payload["agentId"] as? String {
                agents.removeValue(forKey: agentId)
                pendingAttention.removeValue(forKey: agentId)
            }
            return
        }
        guard kind == "upsert", let dictionary = payload["agent"] as? [String: Any] else { return }
        let existing = (dictionary["id"] as? String).flatMap { agents[$0] }
        guard var agent = Agent(
            dictionary: dictionary,
            project: payload["project"] as? [String: Any]
        ) else { return }
        if agent.projectName == nil { agent.projectName = existing?.projectName }
        if agent.workspaceName == nil { agent.workspaceName = existing?.workspaceName }
        mergePendingAttention(into: &agent)
        agents[agent.id] = agent
    }

    func applyAttention(payload: [String: Any]) {
        guard let agentId = payload["agentId"] as? String,
              let reason = payload["reason"] as? String else { return }
        let timestamp = TrayDate.parse(payload["timestamp"]) ?? Date()
        prunePendingAttention()
        if var agent = agents[agentId] {
            agent.markAttention(reason: reason, timestamp: timestamp)
            agents[agentId] = agent
            return
        }
        pendingAttention[agentId] = PendingAttention(
            reason: reason,
            timestamp: timestamp,
            receivedAt: Date()
        )
        enforcePendingLimit()
    }

    /// Internal for the pure self-check. Expired entries are never applied.
    func prunePendingAttention(now: Date = Date()) {
        pendingAttention = pendingAttention.filter {
            now.timeIntervalSince($0.value.receivedAt) < Self.pendingAttentionTTL
        }
    }

    private func mergePendingAttention(into agent: inout Agent, now: Date = Date()) {
        guard let pending = pendingAttention[agent.id] else { return }
        pendingAttention.removeValue(forKey: agent.id)
        guard now.timeIntervalSince(pending.receivedAt) < Self.pendingAttentionTTL else { return }
        agent.markAttention(reason: pending.reason, timestamp: pending.timestamp)
    }

    private func enforcePendingLimit() {
        guard pendingAttention.count > Self.pendingAttentionLimit else { return }
        let overflow = pendingAttention.count - Self.pendingAttentionLimit
        let oldest = pendingAttention
            .sorted { $0.value.receivedAt < $1.value.receivedAt }
            .prefix(overflow)
        for (key, _) in oldest {
            pendingAttention.removeValue(forKey: key)
        }
    }

    func visible(config: TrayConfig) -> [Agent] {
        agents.values.filter { agent in
            guard !agent.background, !agent.internalAgent, agent.archivedAt == nil else {
                return false
            }
            if !config.includeSubagents && agent.isSubagent { return false }
            return agent.bucket != .done
        }
    }

    func counts(config: TrayConfig) -> AgentCounts {
        var counts = AgentCounts()
        for agent in visible(config: config) {
            switch agent.bucket {
            case .needsInput: counts.needsInput += 1
            case .failed: counts.failed += 1
            case .running: counts.running += 1
            case .attention: counts.finished += 1
            case .done: break
            }
        }
        return counts
    }

    func sections(config: TrayConfig) -> AgentSections {
        let visible = visible(config: config)
        var sections = AgentSections()
        sections.needsInput = visible
            .filter { $0.bucket == .needsInput }
            .sorted(by: ascendingByAttention)
        sections.failed = visible
            .filter { $0.bucket == .failed }
            .sorted(by: ascendingByAttention)
        sections.running = visible
            .filter { $0.bucket == .running }
            .sorted(by: ascendingByRun)
        sections.attention = visible
            .filter { $0.bucket == .attention }
            .sorted(by: descendingByAttention)
        return sections
    }

    private func ascendingByAttention(_ lhs: Agent, _ rhs: Agent) -> Bool {
        let left = lhs.attentionTimestamp ?? lhs.updatedAt
        let right = rhs.attentionTimestamp ?? rhs.updatedAt
        if left == right { return lhs.updatedAt < rhs.updatedAt }
        return left < right
    }

    private func descendingByAttention(_ lhs: Agent, _ rhs: Agent) -> Bool {
        let left = lhs.attentionTimestamp ?? lhs.updatedAt
        let right = rhs.attentionTimestamp ?? rhs.updatedAt
        if left == right { return lhs.updatedAt > rhs.updatedAt }
        return left > right
    }

    private func ascendingByRun(_ lhs: Agent, _ rhs: Agent) -> Bool {
        let left = lhs.activeTurnStartedAt ?? lhs.updatedAt
        let right = rhs.activeTurnStartedAt ?? rhs.updatedAt
        if left == right { return lhs.updatedAt < rhs.updatedAt }
        return left < right
    }
}

// MARK: - Demo data

extension AgentStore {
    static func demoEntries() -> [[String: Any]] {
        let now = Date()
        func iso(_ date: Date) -> String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return formatter.string(from: date)
        }
        func entry(
            id: String,
            title: String,
            provider: String,
            status: String,
            requiresAttention: Bool,
            attentionReason: String? = nil,
            attentionTimestamp: Date? = nil,
            pendingPermissions: [[String: Any]] = [],
            activeTurnStartedAt: Date? = nil
        ) -> [String: Any] {
            var agent: [String: Any] = [
                "id": id,
                "title": title,
                "provider": provider,
                "status": status,
                "requiresAttention": requiresAttention,
                "pendingPermissions": pendingPermissions,
                "labels": [:],
                "background": false,
                "internal": false,
                "updatedAt": iso(now),
                "createdAt": iso(now.addingTimeInterval(-3600)),
            ]
            if let attentionReason { agent["attentionReason"] = attentionReason }
            if let attentionTimestamp { agent["attentionTimestamp"] = iso(attentionTimestamp) }
            if let activeTurnStartedAt {
                agent["activeTurn"] = ["turnId": "turn-\(id)", "startedAt": iso(activeTurnStartedAt)]
            }
            return [
                "agent": agent,
                "project": [
                    "projectName": "Paseo Tray",
                    "workspaceName": "Demo",
                ],
            ]
        }

        return [
            entry(
                id: "demo-needs-input",
                title: "Fix login bug",
                provider: "claude",
                status: "idle",
                requiresAttention: true,
                attentionReason: "permission",
                attentionTimestamp: now.addingTimeInterval(-120),
                pendingPermissions: [["requestId": "demo-permission"]]
            ),
            entry(
                id: "demo-running-1",
                title: "Refactor auth",
                provider: "opencode",
                status: "running",
                requiresAttention: false,
                activeTurnStartedAt: now.addingTimeInterval(-300)
            ),
            entry(
                id: "demo-running-2",
                title: "Write tests",
                provider: "codex",
                status: "running",
                requiresAttention: false,
                activeTurnStartedAt: now.addingTimeInterval(-60)
            ),
            entry(
                id: "demo-finished-1",
                title: "Update docs",
                provider: "claude",
                status: "idle",
                requiresAttention: true,
                attentionReason: "finished",
                attentionTimestamp: now.addingTimeInterval(-720)
            ),
        ]
    }

    static func demo() -> AgentStore {
        let store = AgentStore()
        store.replace(entries: demoEntries(), hasMore: false)
        return store
    }
}

// MARK: - Pure self-check

extension AgentStore {
    static func runSelfCheck() -> Bool {
        var failures: [String] = []
        var assertions = 0
        func expect(_ condition: Bool, _ message: String) {
            assertions += 1
            if !condition { failures.append(message) }
        }

        func dictionary(
            id: String,
            status: String,
            requiresAttention: Bool = false,
            attentionReason: String? = nil,
            attentionTimestamp: String? = nil,
            pendingPermissions: Int = 0,
            labels: [String: String] = [:],
            background: Bool = false,
            internalAgent: Bool = false,
            archivedAt: String? = nil,
            activeTurnStartedAt: String? = nil
        ) -> [String: Any] {
            var agent: [String: Any] = [
                "id": id,
                "title": id,
                "provider": "test",
                "status": status,
                "requiresAttention": requiresAttention,
                "pendingPermissions": Array(repeating: [String: Any](), count: pendingPermissions),
                "labels": labels,
                "background": background,
                "internal": internalAgent,
                "updatedAt": "2026-11-05T10:00:00.000Z",
                "createdAt": "2026-11-05T09:00:00.000Z",
            ]
            if let attentionReason { agent["attentionReason"] = attentionReason }
            if let attentionTimestamp { agent["attentionTimestamp"] = attentionTimestamp }
            if let archivedAt { agent["archivedAt"] = archivedAt }
            if let activeTurnStartedAt {
                agent["activeTurn"] = ["turnId": "t", "startedAt": activeTurnStartedAt]
            }
            return ["agent": agent, "project": ["projectName": "P", "workspaceName": "W"]]
        }

        let entries = [
            dictionary(id: "running", status: "running", activeTurnStartedAt: "2026-11-05T09:55:00.000Z"),
            dictionary(id: "attention", status: "idle", requiresAttention: true, attentionReason: "finished", attentionTimestamp: "2026-11-05T09:50:00.000Z"),
            dictionary(id: "permission", status: "idle", requiresAttention: true, attentionReason: "permission", attentionTimestamp: "2026-11-05T09:40:00.000Z", pendingPermissions: 1),
            dictionary(id: "failed", status: "error", attentionReason: "error", attentionTimestamp: "2026-11-05T09:45:00.000Z"),
            dictionary(id: "done", status: "idle"),
            dictionary(id: "background", status: "running", background: true),
            dictionary(id: "internal", status: "running", internalAgent: true),
            dictionary(id: "subagent", status: "running", labels: ["paseo.parent-agent-id": "parent"]),
            dictionary(id: "archived", status: "running", archivedAt: "2026-11-05T09:00:00.000Z"),
        ]

        let store = AgentStore()
        store.replace(entries: entries, hasMore: false)
        var config = TrayConfig.defaults
        var counts = store.counts(config: config)
        expect(counts.running == 1, "default running count should be 1, got \(counts.running)")
        expect(counts.finished == 1, "default finished count should be 1, got \(counts.finished)")
        expect(counts.needsInput == 1, "default needsInput count should be 1, got \(counts.needsInput)")
        expect(counts.failed == 1, "default failed count should be 1, got \(counts.failed)")
        expect(counts.actionable == 2, "default actionable should be 2, got \(counts.actionable)")

        config.includeSubagents = true
        counts = store.counts(config: config)
        expect(counts.running == 2, "subagent included running count should be 2, got \(counts.running)")

        let sections = store.sections(config: TrayConfig.defaults)
        expect(sections.needsInput.map(\.id) == ["permission"], "needsInput section ordering")
        expect(sections.failed.map(\.id) == ["failed"], "failed section ordering")
        expect(sections.running.map(\.id) == ["running"], "running section ordering")
        expect(sections.attention.map(\.id) == ["attention"], "attention section ordering")

        let agent = Agent(dictionary: [
            "id": "buckets",
            "provider": "test",
            "status": "running",
            "requiresAttention": true,
            "attentionReason": "permission",
            "pendingPermissions": [[String: Any]](),
        ])!
        expect(agent.bucket == .needsInput, "permission bucket must win over running")

        let errorAgent = Agent(dictionary: [
            "id": "error",
            "provider": "test",
            "status": "error",
        ])!
        expect(errorAgent.bucket == .failed, "error status must map to failed")

        let attentionAgent = Agent(dictionary: [
            "id": "attention",
            "provider": "test",
            "status": "idle",
            "requiresAttention": true,
            "attentionReason": "finished",
        ])!
        expect(attentionAgent.bucket == .attention, "requiresAttention must map to attention")

        let doneAgent = Agent(dictionary: [
            "id": "done",
            "provider": "test",
            "status": "idle",
        ])!
        expect(doneAgent.bucket == .done, "plain idle must map to done")

        // Attention can arrive before the matching agent snapshot. It must be
        // buffered and merged into the next upsert/snapshot.
        let pendingStore = AgentStore()
        pendingStore.applyAttention(payload: [
            "agentId": "late",
            "reason": "finished",
            "timestamp": "2026-11-05T09:00:00.000Z",
        ])
        expect(pendingStore.pendingAttentionCount == 1, "attention before snapshot must be pending")
        pendingStore.replace(
            entries: [dictionary(
                id: "late",
                status: "running",
                activeTurnStartedAt: "2026-11-05T09:55:00.000Z"
            )],
            hasMore: false
        )
        let lateSections = pendingStore.sections(config: TrayConfig.defaults)
        expect(lateSections.attention.map(\.id) == ["late"], "pending attention must merge into snapshot")
        expect(pendingStore.pendingAttentionCount == 0, "merged pending attention must be removed")

        let limitStore = AgentStore()
        for index in 0..<105 {
            limitStore.applyAttention(payload: [
                "agentId": "pending-\(index)",
                "reason": "finished",
                "timestamp": "2026-11-05T09:00:00.000Z",
            ])
        }
        expect(limitStore.pendingAttentionCount == 100, "pending attention must be capped at 100")
        limitStore.prunePendingAttention(now: Date().addingTimeInterval(301))
        expect(limitStore.pendingAttentionCount == 0, "pending attention must expire after 5 minutes")

        let gate = AttentionGate(window: 600)
        let now = Date()
        expect(gate.accept(agentId: "a", reason: "finished", timestamp: now, now: now), "first attention is new")
        expect(!gate.accept(agentId: "a", reason: "finished", timestamp: now, now: now), "duplicate attention is rejected")
        expect(gate.accept(agentId: "a", reason: "error", timestamp: now, now: now), "different reason is new")
        expect(
            gate.accept(agentId: "a", reason: "finished", timestamp: now, now: now.addingTimeInterval(601)),
            "attention is accepted again after the 10-minute window"
        )

        var notifyConfig = TrayConfig.defaults
        expect(!NotificationPolicy.shouldNotify(reason: "finished", config: notifyConfig), "finish notification is off by default")
        notifyConfig.notifyOnFinish = true
        expect(NotificationPolicy.shouldNotify(reason: "finished", config: notifyConfig), "finish notification respects the setting")
        expect(!NotificationPolicy.shouldNotify(reason: "permission", config: notifyConfig), "permission notification respects the setting")
        expect(NotificationPolicy.shouldAnnounce(isNew: true, paseoFrontmost: false), "new attention should flash")
        expect(!NotificationPolicy.shouldAnnounce(isNew: true, paseoFrontmost: true), "frontmost Paseo suppresses flash")
        expect(!NotificationPolicy.shouldAnnounce(isNew: false, paseoFrontmost: false), "duplicate attention should not flash")
        expect(
            NotificationPolicy.authorizationAction(for: .authorized) == .authorized,
            "authorized notification status"
        )
        expect(
            NotificationPolicy.authorizationAction(for: .denied) == .denied,
            "denied notification status"
        )
        expect(
            NotificationPolicy.authorizationAction(for: .notDetermined) == .request,
            "notDetermined notification status requests permission"
        )

        if failures.isEmpty {
            print("self-check: OK (\(assertions) assertions)")
            return true
        }
        for failure in failures {
            print("self-check: FAIL — \(failure)")
        }
        return false
    }
}
