import AppKit
import Foundation

struct TrayConfig: Equatable, Codable {
    var showRunningCount: Bool = true
    var showFinishedCount: Bool = true
    // The tray is silent by default: Paseo already sends its own notifications.
    // Users opt in per reason in the plugin settings.
    var notifyOnFinish: Bool = false
    var notifyOnError: Bool = false
    var notifyOnPermission: Bool = false
    var playSound: Bool = false
    var includeSubagents: Bool = false

    static let defaults = TrayConfig()

    var anyNotificationEnabled: Bool {
        notifyOnFinish || notifyOnError || notifyOnPermission
    }

    var jsonObject: [String: Any] {
        [
            "showRunningCount": showRunningCount,
            "showFinishedCount": showFinishedCount,
            "notifyOnFinish": notifyOnFinish,
            "notifyOnError": notifyOnError,
            "notifyOnPermission": notifyOnPermission,
            "playSound": playSound,
            "includeSubagents": includeSubagents,
        ]
    }
}

/// Loads the shared config file and watches its directory for atomic renames.
final class TrayConfigStore {
    let fileURL: URL
    private let directoryURL: URL
    private let fileManager = FileManager.default
    private var source: DispatchSourceFileSystemObject?
    private var directoryFD: Int32 = -1
    private var reloadWorkItem: DispatchWorkItem?
    private var reinstallWorkItem: DispatchWorkItem?
    private var handler: ((TrayConfig, String?) -> Void)?
    private(set) var lastError: String?

    init(fileURL: URL? = nil) {
        let resolved: URL
        if let fileURL {
            resolved = fileURL
        } else if let override = ProcessInfo.processInfo.environment["PASEOTRAY_CONFIG_PATH"],
                  !override.isEmpty {
            resolved = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        } else {
            let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            resolved = support
                .appendingPathComponent("PaseoTray", isDirectory: true)
                .appendingPathComponent("config.json")
        }
        self.fileURL = resolved
        self.directoryURL = resolved.deletingLastPathComponent()
    }

    var displayPath: String {
        let home = NSHomeDirectory()
        let path = fileURL.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func load() -> (config: TrayConfig, error: String?) {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            lastError = nil
            return (.defaults, nil)
        }
        do {
            let data = try Data(contentsOf: fileURL)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ConfigError.invalid("根节点不是 JSON 对象")
            }
            lastError = nil
            var config = TrayConfig.defaults
            config.showRunningCount = bool(object, "showRunningCount", config.showRunningCount)
            config.showFinishedCount = bool(object, "showFinishedCount", config.showFinishedCount)
            config.notifyOnFinish = bool(object, "notifyOnFinish", config.notifyOnFinish)
            config.notifyOnError = bool(object, "notifyOnError", config.notifyOnError)
            config.notifyOnPermission = bool(object, "notifyOnPermission", config.notifyOnPermission)
            config.playSound = bool(object, "playSound", config.playSound)
            config.includeSubagents = bool(object, "includeSubagents", config.includeSubagents)
            return (config, lastError)
        } catch {
            let message = "配置读取失败：\(error.localizedDescription)"
            lastError = message
            return (.defaults, message)
        }
    }

    func ensureDefaultFile() throws {
        guard !fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(TrayConfig.defaults)
        try data.write(to: fileURL, options: [.atomic])
        trayLog("已创建默认配置：\(displayPath)")
    }

    func startWatching(_ handler: @escaping (TrayConfig, String?) -> Void) {
        self.handler = handler
        installSource()
        reload()
    }

    func stopWatching() {
        reloadWorkItem?.cancel()
        reinstallWorkItem?.cancel()
        reloadWorkItem = nil
        reinstallWorkItem = nil
        source?.cancel()
        source = nil
        directoryFD = -1
        handler = nil
    }

    func revealInFinder() {
        try? ensureDefaultFile()
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    private func bool(_ object: [String: Any], _ key: String, _ fallback: Bool) -> Bool {
        if let value = object[key] as? Bool { return value }
        if object[key] != nil {
            lastError = "配置字段 \(key) 类型不正确，已使用默认值"
        }
        return fallback
    }

    private func installSource() {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let fd = open(directoryURL.path, O_EVTONLY)
            guard fd >= 0 else {
                throw ConfigError.invalid("无法监听配置目录")
            }
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: fd,
                eventMask: [.write, .delete, .rename, .link, .attrib, .extend],
                queue: .main
            )
            source.setEventHandler { [weak self] in
                guard let self else { return }
                let events = self.source?.data ?? []
                self.scheduleReload()
                if events.contains(.delete) || events.contains(.rename) {
                    self.scheduleReinstall()
                }
            }
            source.setCancelHandler {
                close(fd)
            }
            source.resume()
            self.source = source
            self.directoryFD = fd
        } catch {
            trayLog("配置目录监听失败：\(error.localizedDescription)")
        }
    }

    private func scheduleReload() {
        reloadWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, let handler = self.handler else { return }
            let loaded = self.load()
            handler(loaded.config, loaded.error)
        }
        reloadWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func scheduleReinstall() {
        reinstallWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.source?.cancel()
            self.source = nil
            self.directoryFD = -1
            self.installSource()
        }
        reinstallWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    private func reload() {
        guard let handler else { return }
        let loaded = load()
        handler(loaded.config, loaded.error)
    }
}

private enum ConfigError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .invalid(let message): return message
        }
    }
}
