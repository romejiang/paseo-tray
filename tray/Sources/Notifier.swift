import AppKit
import Foundation
import UserNotifications

final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var config: TrayConfig
    private var authorizationRequested = false
    private var authorizationCheckInFlight = false
    private var authorized = false
    private var unavailable = false
    private let gate = AttentionGate()

    var isPaseoFrontmost: () -> Bool = {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "sh.paseo.desktop"
    }
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var fallback: () -> Void = { NSSound.beep() }

    private var center: UNUserNotificationCenter? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }

    init(config: TrayConfig) {
        self.config = config
        super.init()
        if let center {
            center.delegate = self
        }
        if config.anyNotificationEnabled {
            refreshAuthorizationIfNeeded()
        }
    }

    func updateConfig(_ config: TrayConfig) {
        self.config = config
        if config.anyNotificationEnabled {
            refreshAuthorizationIfNeeded()
        }
    }

    func notify(agent: Agent?, agentId: String, reason: String, timestamp: Date, deepLink: URL?) {
        guard gate.accept(agentId: agentId, reason: reason, timestamp: timestamp) else { return }
        guard NotificationPolicy.shouldNotify(reason: reason, config: config) else { return }
        if isPaseoFrontmost() {
            trayLog("Paseo 在前台，跳过通知：\(agentId) \(reason)")
            return
        }

        guard let center, authorized, !unavailable else {
            fallback()
            return
        }

        let key = "\(agentId)|\(reason)|\(timestamp.timeIntervalSince1970)"
        let content = UNMutableNotificationContent()
        content.title = title(for: reason)
        content.body = body(for: agent, agentId: agentId)
        content.threadIdentifier = "paseo-tray"
        content.sound = config.playSound ? .default : nil
        if let deepLink {
            content.userInfo = ["deepLink": deepLink.absoluteString]
        }
        let request = UNNotificationRequest(identifier: key, content: content, trigger: nil)
        center.add(request) { [weak self] error in
            guard let error else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.unavailable = true
                trayLog("通知发送失败，降级为 beep：\(error.localizedDescription)")
                self.fallback()
            }
        }
    }

    func sendTestNotification() {
        guard let center else {
            trayLog("通知不可用，改为 beep")
            fallback()
            return
        }
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                switch NotificationPolicy.authorizationAction(for: settings.authorizationStatus) {
                case .authorized:
                    self.authorized = true
                    self.unavailable = false
                    self.deliverTestNotification(center: center)
                case .denied:
                    self.authorized = false
                    self.unavailable = true
                    trayLog("测试通知被系统拒绝，改为 beep")
                    self.fallback()
                case .request:
                    self.requestAuthorization { granted in
                        guard granted else {
                            self.fallback()
                            return
                        }
                        self.deliverTestNotification(center: center)
                    }
                }
            }
        }
    }

    private func deliverTestNotification(center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Paseo Tray"
        content.body = "通知已启用。完成、失败和权限事件会显示在这里。"
        content.threadIdentifier = "paseo-tray"
        content.sound = config.playSound ? .default : nil
        let request = UNNotificationRequest(
            identifier: "paseo-tray-test-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                trayLog("测试通知失败：\(error.localizedDescription)")
            } else {
                trayLog("测试通知已提交")
            }
        }
    }

    private func title(for reason: String) -> String {
        switch reason {
        case "finished": return "Agent 已完成"
        case "error": return "Agent 出错"
        case "permission": return "Agent 需要你的输入"
        default: return "Paseo"
        }
    }

    private func body(for agent: Agent?, agentId: String) -> String {
        guard let agent else { return "Agent \(String(agentId.prefix(8)))" }
        var parts = [agent.displayTitle]
        parts.append(agent.provider)
        if let project = agent.projectName, !project.isEmpty {
            parts.append(project)
        }
        return parts.joined(separator: " · ")
    }

    /// Read the current authorization first. Only `.notDetermined` prompts;
    /// `.authorized` must be usable immediately at launch.
    private func refreshAuthorizationIfNeeded() {
        guard let center else {
            unavailable = true
            return
        }
        guard !authorizationCheckInFlight else { return }
        authorizationCheckInFlight = true
        center.getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorizationCheckInFlight = false
                switch NotificationPolicy.authorizationAction(for: settings.authorizationStatus) {
                case .authorized:
                    self.authorized = true
                    self.unavailable = false
                case .denied:
                    self.authorized = false
                    self.unavailable = true
                    trayLog("通知被系统拒绝，将使用 beep + 图标闪烁降级")
                case .request:
                    self.requestAuthorization { _ in }
                }
            }
        }
    }

    private func requestAuthorization(completion: @escaping (Bool) -> Void) {
        guard !authorizationRequested else {
            completion(authorized)
            return
        }
        guard let center else {
            unavailable = true
            completion(false)
            return
        }
        authorizationRequested = true
        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.authorized = granted && error == nil
                self.unavailable = !self.authorized
                if let error {
                    trayLog("通知授权失败：\(error.localizedDescription)")
                } else if !granted {
                    trayLog("通知未授权，将使用 beep + 图标闪烁降级")
                }
                completion(self.authorized)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let value = response.notification.request.content.userInfo["deepLink"] as? String,
           let url = URL(string: value) {
            DispatchQueue.main.async { [weak self] in
                self?.openURL(url)
            }
        }
        completionHandler()
    }
}
