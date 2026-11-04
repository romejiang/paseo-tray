import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate, PaseoClientDelegate, MenuControllerDelegate {
    private let isDemo: Bool
    private let store = AgentStore()
    private var configStore: TrayConfigStore!
    private var config = TrayConfig.defaults
    private var menuController: MenuController!
    private var client: PaseoClient?
    private var notifier: Notifier!
    private var connection = PaseoConnectionStatus()
    private var serverId: String?
    private var wakeObserver: NSObjectProtocol?
    private let announceGate = AttentionGate()

    init(demo: Bool) {
        self.isDemo = demo
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configStore = TrayConfigStore()
        let loaded = configStore.load()
        config = loaded.config
        if let error = loaded.error {
            trayLog(error)
        }

        notifier = Notifier(config: config)
        notifier.isPaseoFrontmost = {
            NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "sh.paseo.desktop"
        }
        notifier.openURL = { [weak self] url in
            self?.open(url)
        }
        notifier.fallback = { [weak self] in
            NSSound.beep()
            self?.menuController.flash()
        }

        if isDemo {
            store.replace(entries: AgentStore.demoEntries(), hasMore: false)
            connection = PaseoConnectionStatus(
                phase: .connected,
                detail: "Demo",
                serverVersion: "demo",
                subscriptionError: nil
            )
            serverId = "srv_demo"
        }

        menuController = MenuController(
            store: store,
            config: config,
            connection: connection,
            serverId: serverId,
            isDemo: isDemo
        )
        menuController.delegate = self

        configStore.startWatching { [weak self] config, error in
            guard let self else { return }
            self.config = config
            self.notifier.updateConfig(config)
            self.menuController.update(
                store: self.store,
                config: config,
                connection: self.connection,
                serverId: self.serverId
            )
            if let error {
                trayLog(error)
            }
        }

        if !isDemo {
            let client = PaseoClient(delegate: self)
            self.client = client
            client.start()
        }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.client?.reconnectNow()
        }

        if ProcessInfo.processInfo.environment["PASEOTRAY_OPEN_MENU"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.menuController.openMenu()
            }
        }

        if isDemo {
            trayLog("Demo 模式启动")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        client?.stop()
        configStore?.stopWatching()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
    }

    // MARK: - PaseoClientDelegate

    func paseoClient(_ client: PaseoClient, event: PaseoClientEvent) {
        switch event {
        case .status(let status):
            connection = status
            refreshMenu()
        case .snapshot(let entries, let hasMore, let serverId):
            store.replace(entries: entries, hasMore: hasMore)
            self.serverId = serverId
            refreshMenu()
        case .agentUpdate(let payload):
            store.apply(update: payload)
            refreshMenu()
        case .attention(let payload):
            store.applyAttention(payload: payload)
            refreshMenu()
            guard let agentId = payload["agentId"] as? String,
                  let reason = payload["reason"] as? String else { return }
            let timestamp = TrayDate.parse(payload["timestamp"]) ?? Date()
            let isNew = announceGate.accept(
                agentId: agentId,
                reason: reason,
                timestamp: timestamp
            )
            let paseoFrontmost = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                == "sh.paseo.desktop"
            if NotificationPolicy.shouldAnnounce(isNew: isNew, paseoFrontmost: paseoFrontmost) {
                menuController.flash()
            }
            if isNew && !paseoFrontmost {
                notifier.notify(
                    agent: store.agents[agentId],
                    agentId: agentId,
                    reason: reason,
                    timestamp: timestamp,
                    deepLink: deepLink(agentId: agentId)
                )
            }
        }
    }

    private func refreshMenu() {
        menuController.update(
            store: store,
            config: config,
            connection: connection,
            serverId: serverId
        )
    }

    // MARK: - MenuControllerDelegate

    func menuControllerOpenAgent(_ agentId: String) {
        guard let url = deepLink(agentId: agentId) else {
            NSSound.beep()
            return
        }
        open(url)
    }

    func menuControllerOpenPaseo() {
        guard let appURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "sh.paseo.desktop"
        ) else {
            showAlert(title: "未找到 Paseo", message: "请确认 /Applications/Paseo.app 已安装。")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, error in
            if let error {
                DispatchQueue.main.async {
                    self.showAlert(title: "无法打开 Paseo", message: error.localizedDescription)
                }
            }
        }
    }

    func menuControllerToggleLoginItem() {
        switch LoginItem.status {
        case .enabled:
            do {
                try LoginItem.unregister()
                menuController.setLoginItemError(nil)
            } catch {
                menuController.setLoginItemError(error.localizedDescription)
                showAlert(title: "关闭登录自启失败", message: error.localizedDescription)
            }
        case .requiresApproval:
            menuController.setLoginItemError(nil)
            LoginItem.openSystemSettings()
        default:
            do {
                try LoginItem.register()
                menuController.setLoginItemError(nil)
                if LoginItem.status == .requiresApproval {
                    LoginItem.openSystemSettings()
                }
            } catch {
                menuController.setLoginItemError(error.localizedDescription)
                showAlert(title: "开启登录自启失败", message: error.localizedDescription)
            }
        }
        refreshMenu()
    }

    func menuControllerRevealConfig() {
        configStore.revealInFinder()
    }

    func menuControllerQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func deepLink(agentId: String) -> URL? {
        guard let serverId, !serverId.isEmpty else { return nil }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        guard let server = serverId.addingPercentEncoding(withAllowedCharacters: allowed),
              let agent = agentId.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        return URL(string: "paseo://h/\(server)/agent/\(agent)")
    }

    private func open(_ url: URL) {
        if !NSWorkspace.shared.open(url) {
            trayLog("无法打开深链：\(url.absoluteString)")
            NSSound.beep()
        }
    }

    private func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
