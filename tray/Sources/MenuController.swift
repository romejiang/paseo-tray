import AppKit
import Foundation

protocol MenuControllerDelegate: AnyObject {
    func menuControllerOpenAgent(_ agentId: String)
    func menuControllerOpenPaseo()
    func menuControllerToggleLoginItem()
    func menuControllerRevealConfig()
    func menuControllerQuit()
}

final class MenuController {
    weak var delegate: MenuControllerDelegate?

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let store: AgentStore
    private var config: TrayConfig
    private var connection: PaseoConnectionStatus
    private var serverId: String?
    private let isDemo: Bool
    private let baseImage: NSImage?
    private var refreshTimer: Timer?
    private var flashTimer: Timer?
    private var flashCount = 0
    private var loginItemError: String?

    init(
        store: AgentStore,
        config: TrayConfig,
        connection: PaseoConnectionStatus,
        serverId: String?,
        isDemo: Bool
    ) {
        self.store = store
        self.config = config
        self.connection = connection
        self.serverId = serverId
        self.isDemo = isDemo
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.baseImage = Self.loadTrayImage()

        menu.autoenablesItems = false
        statusItem.menu = menu
        if let button = statusItem.button {
            button.image = baseImage
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.toolTip = "Paseo Tray"
        }

        refresh()
        startRefreshTimer()

        if ProcessInfo.processInfo.environment["PASEOTRAY_DEBUG"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self else { return }
                var lines: [String] = []
                lines.append("bundle=\(Bundle.main.bundleIdentifier ?? "nil") path=\(Bundle.main.bundlePath)")
                lines.append("screens=\(NSScreen.screens.map { NSStringFromRect($0.frame) })")
                if let button = self.statusItem.button, let window = button.window {
                    lines.append(
                        "status item frame=\(NSStringFromRect(window.frame)) visible=\(window.isVisible) " +
                        "screen=\(String(describing: window.screen.map { NSStringFromRect($0.frame) }))"
                    )
                } else {
                    lines.append("status item has no button/window")
                }
                let text = lines.joined(separator: "\n") + "\n"
                try? text.write(toFile: "/tmp/paseo-tray-debug.log", atomically: true, encoding: .utf8)
                trayLog(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
    }

    deinit {
        refreshTimer?.invalidate()
        flashTimer?.invalidate()
    }

    func update(
        store: AgentStore,
        config: TrayConfig,
        connection: PaseoConnectionStatus,
        serverId: String?
    ) {
        self.config = config
        self.connection = connection
        self.serverId = serverId
        _ = store
        refresh()
    }

    func openMenu() {
        statusItem.button?.performClick(nil)
    }

    func setLoginItemError(_ message: String?) {
        loginItemError = message
        refresh()
    }

    func flash() {
        flashTimer?.invalidate()
        flashCount = 0
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] timer in
            guard let self, let button = self.statusItem.button else {
                timer.invalidate()
                return
            }
            self.flashCount += 1
            button.alphaValue = self.flashCount % 2 == 0 ? 1.0 : 0.35
            if self.flashCount >= 8 {
                timer.invalidate()
                button.alphaValue = 1.0
                self.flashTimer = nil
            }
        }
        flashTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func startRefreshTimer() {
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func refresh() {
        updateStatusItem()
        rebuildMenu()
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        button.image = baseImage

        if connection.phase != .connected {
            button.appearsDisabled = true
            button.imagePosition = .imageLeft
            button.attributedTitle = attributed(
                segments: [("–", NSColor.secondaryLabelColor)],
                font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            )
            button.toolTip = "Paseo Tray · \(connection.detail)"
            return
        }

        button.appearsDisabled = false
        let counts = store.counts(config: config)
        var segments: [(String, NSColor)] = []
        if config.showRunningCount && counts.running > 0 {
            segments.append(("▶ \(counts.running)", NSColor.labelColor))
        }
        if config.showFinishedCount && counts.finished > 0 {
            segments.append(("✓ \(counts.finished)", NSColor.labelColor))
        }
        if counts.actionable > 0 {
            segments.append(("! \(counts.actionable)", NSColor.systemRed))
        }

        if segments.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
        } else {
            button.imagePosition = .imageLeft
            button.attributedTitle = attributed(
                segments: segments,
                font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            )
        }
        var tip = "Paseo Tray · \(counts.running) 运行中 · \(counts.finished) 已完成"
        if counts.actionable > 0 {
            tip += " · \(counts.actionable) 需要处理"
        }
        if let subscriptionError = connection.subscriptionError {
            tip += " · \(subscriptionError)"
        }
        button.toolTip = tip
    }

    private func attributed(segments: [(String, NSColor)], font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, segment) in segments.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(
                    string: "  ",
                    attributes: [.font: font, .foregroundColor: NSColor.labelColor]
                ))
            }
            result.append(NSAttributedString(
                string: segment.0,
                attributes: [.font: font, .foregroundColor: segment.1]
            ))
        }
        return result
    }

    private func rebuildMenu() {
        menu.removeAllItems()

        if connection.phase != .connected {
            addHeader(connectionHeaderTitle())
            if !connection.detail.isEmpty {
                addDisabled(connection.detail)
            }
            if connection.phase == .authRequired {
                addAction("打开 Paseo", action: #selector(openPaseo))
            }
            if connection.phase == .unsupported {
                addDisabled("v1 仅支持 host:port 形式的 daemon listen")
            }
        } else {
            if let subscriptionError = connection.subscriptionError {
                addDisabled("订阅失败：\(subscriptionError)")
            }
            let sections = store.sections(config: config)
            if sections.isEmpty {
                addDisabled("暂无 agent")
            } else {
                if !sections.needsInput.isEmpty {
                    addHeader("需要你处理")
                    addAgents(sections.needsInput, color: .systemOrange)
                }
                if !sections.failed.isEmpty {
                    addHeader("失败")
                    addAgents(sections.failed, color: .systemRed)
                }
                if !sections.running.isEmpty {
                    addHeader("运行中")
                    addAgents(sections.running, color: .systemGreen)
                }
                if !sections.attention.isEmpty {
                    addHeader("已完成")
                    addAgents(sections.attention, color: .secondaryLabelColor)
                }
                if store.hasMore {
                    addDisabled("只显示前 200 个")
                }
            }
        }

        menu.addItem(.separator())
        addAction("打开 Paseo", action: #selector(openPaseo))

        let loginItem = NSMenuItem(
            title: loginItemTitle(),
            action: #selector(toggleLoginItem),
            keyEquivalent: ""
        )
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : (LoginItem.requiresApproval ? .mixed : .off)
        if let loginItemError {
            loginItem.title = "登录时启动（失败）"
            loginItem.isEnabled = false
            loginItem.toolTip = loginItemError
        }
        menu.addItem(loginItem)

        addAction("托盘设置…", action: #selector(revealConfig))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        if connection.phase == .connected {
            var statusParts: [String] = []
            if let version = connection.serverVersion, !version.isEmpty {
                statusParts.append("Paseo \(version)")
            }
            if let serverId, !serverId.isEmpty {
                statusParts.append(serverId)
            }
            if !statusParts.isEmpty {
                addDisabled(statusParts.joined(separator: " · "))
            }
        }
    }

    private func connectionHeaderTitle() -> String {
        switch connection.phase {
        case .offline: return "Paseo 未连接"
        case .connecting: return "正在连接 Paseo…"
        case .connected: return "Paseo"
        case .authRequired: return "需要密码"
        case .unsupported: return "不支持的连接"
        }
    }

    private func loginItemTitle() -> String {
        switch LoginItem.status {
        case .enabled: return "登录时启动"
        case .requiresApproval: return "登录时启动（需在系统设置中批准）"
        default: return "登录时启动"
        }
    }

    private func addHeader(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        item.attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        menu.addItem(item)
    }

    private func addDisabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    private func addAction(_ title: String, action: Selector, keyEquivalent: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        menu.addItem(item)
    }

    private func addAgents(_ agents: [Agent], color: NSColor) {
        for agent in agents {
            let item = NSMenuItem(title: "", action: #selector(openAgent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = agent.id
            item.attributedTitle = agentTitle(agent, color: color)
            var tooltipParts: [String] = [agent.displayTitle, agent.provider]
            if let project = agent.projectName, !project.isEmpty { tooltipParts.append(project) }
            if let workspace = agent.workspaceName, !workspace.isEmpty { tooltipParts.append(workspace) }
            item.toolTip = tooltipParts.joined(separator: "\n")
            menu.addItem(item)
        }
    }

    private func agentTitle(_ agent: Agent, color: NSColor) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let prefix = agent.bucket.menuPrefix + " "
        result.append(NSAttributedString(
            string: prefix,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: color,
            ]
        ))
        result.append(NSAttributedString(
            string: agent.displayTitle,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .regular),
                .foregroundColor: NSColor.labelColor,
            ]
        ))
        let relative = Self.relativeTime(agent.menuTimestamp)
        result.append(NSAttributedString(
            string: " · \(relative)",
            attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        ))
        return result
    }

    private static func relativeTime(_ date: Date) -> String {
        let seconds = max(0, Int(Date().timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        if seconds < 86_400 { return "\(seconds / 3600)h" }
        return "\(seconds / 86_400)d"
    }

    private static func loadTrayImage() -> NSImage? {
        if let image = NSImage(named: "trayTemplate") {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        if let url = Bundle.main.url(forResource: "trayTemplate", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            return image
        }
        if let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Paseo Tray") {
            image.isTemplate = true
            return image
        }
        return nil
    }

    @objc private func openAgent(_ sender: NSMenuItem) {
        guard let agentId = sender.representedObject as? String else { return }
        if isDemo {
            NSSound.beep()
            return
        }
        delegate?.menuControllerOpenAgent(agentId)
    }

    @objc private func openPaseo() {
        delegate?.menuControllerOpenPaseo()
    }

    @objc private func toggleLoginItem() {
        delegate?.menuControllerToggleLoginItem()
    }

    @objc private func revealConfig() {
        delegate?.menuControllerRevealConfig()
    }

    @objc private func quit() {
        delegate?.menuControllerQuit()
    }
}
