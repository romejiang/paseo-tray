import AppKit
import Foundation
import UserNotifications

let arguments = CommandLine.arguments

func hasFlag(_ flag: String) -> Bool {
    arguments.contains(flag)
}

if hasFlag("--version") {
    let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    print("PaseoTray \(version)")
    exit(0)
}

if hasFlag("--bundle-info") {
    print("bundleIdentifier=\(Bundle.main.bundleIdentifier ?? "nil")")
    print("bundlePath=\(Bundle.main.bundlePath)")
    print("infoIdentifier=\(Bundle.main.infoDictionary?["CFBundleIdentifier"] as? String ?? "nil")")
    exit(0)
}

if hasFlag("--icon-info") {
    let tray = NSImage(named: "trayTemplate")
    print("trayTemplate loaded=\(tray != nil) size=\(tray?.size ?? .zero) template=\(tray?.isTemplate ?? false)")
    let appIcon = NSImage(named: "PaseoIcon")
    print("appIcon loaded=\(appIcon != nil) size=\(appIcon?.size ?? .zero)")
    exit(0)
}

if hasFlag("--notification-status") {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        print("authorizationStatus=\(settings.authorizationStatus.rawValue)")
        print("alertSetting=\(settings.alertSetting.rawValue)")
        print("soundSetting=\(settings.soundSetting.rawValue)")
        print("notificationCenterSetting=\(settings.notificationCenterSetting.rawValue)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if hasFlag("--delivered-notifications") {
    let semaphore = DispatchSemaphore(value: 0)
    UNUserNotificationCenter.current().getDeliveredNotifications { notifications in
        for notification in notifications {
            print("\(notification.request.identifier) | \(notification.request.content.title) | \(notification.request.content.body)")
        }
        print("count=\(notifications.count)")
        semaphore.signal()
    }
    semaphore.wait()
    exit(0)
}

if hasFlag("--clear-notifications") {
    UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    print("cleared")
    exit(0)
}

if hasFlag("--self-check") {
    exit(AgentStore.runSelfCheck() ? 0 : 1)
}

if hasFlag("--login-item-status") {
    print(LoginItem.statusText)
    exit(0)
}

if hasFlag("--login-item-register") {
    do {
        try LoginItem.register()
        print("register: \(LoginItem.statusText)")
        exit(0)
    } catch {
        fputs("register failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

if hasFlag("--login-item-unregister") {
    do {
        try LoginItem.unregister()
        print("unregister: \(LoginItem.statusText)")
        exit(0)
    } catch {
        fputs("unregister failed: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

let app = NSApplication.shared
let diagnosticsMode = hasFlag("--selftest") || hasFlag("--watch-json")
let demoMode = hasFlag("--demo")

if hasFlag("--test-notification") {
    app.setActivationPolicy(.prohibited)
    let notifier = Notifier(config: TrayConfig.defaults)
    notifier.sendTestNotification()
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        exit(0)
    }
    app.run()
    exit(0)
}

app.setActivationPolicy(diagnosticsMode ? .prohibited : .accessory)

if diagnosticsMode {
    let diagnostics = Diagnostics(watch: hasFlag("--watch-json"))
    diagnostics.start()
    app.run()
    exit(0)
}

let delegate = AppDelegate(demo: demoMode)
app.delegate = delegate
app.run()
