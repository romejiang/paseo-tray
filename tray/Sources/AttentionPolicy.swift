import Foundation
import UserNotifications

/// 10-minute dedupe for attention events. The same agent/reason/timestamp
/// must only announce once, even if the daemon repeats the event.
final class AttentionGate {
    private var seen: [String: Date] = [:]
    private let window: TimeInterval

    init(window: TimeInterval = 600) {
        self.window = window
    }

    var count: Int { seen.count }

    func accept(agentId: String, reason: String, timestamp: Date, now: Date = Date()) -> Bool {
        prune(now: now)
        let key = "\(agentId)|\(reason)|\(timestamp.timeIntervalSince1970)"
        if seen[key] != nil { return false }
        seen[key] = now
        return true
    }

    func prune(now: Date = Date()) {
        seen = seen.filter { now.timeIntervalSince($0.value) < window }
    }
}

enum NotificationAuthorizationAction: Equatable {
    case authorized
    case denied
    case request
}

enum NotificationPolicy {
    static func shouldNotify(reason: String, config: TrayConfig) -> Bool {
        switch reason {
        case "finished": return config.notifyOnFinish
        case "error": return config.notifyOnError
        case "permission": return config.notifyOnPermission
        default: return false
        }
    }

    /// The tray always announces a new attention event visually when Paseo is
    /// not frontmost, even when system notifications are disabled.
    static func shouldAnnounce(isNew: Bool, paseoFrontmost: Bool) -> Bool {
        isNew && !paseoFrontmost
    }

    static func authorizationAction(for status: UNAuthorizationStatus) -> NotificationAuthorizationAction {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return .authorized
        case .denied:
            return .denied
        case .notDetermined:
            return .request
        @unknown default:
            return .request
        }
    }
}
