import Foundation

/// Small logging shim. Never pass credentials or the local-credential token here.
func trayLog(_ message: String) {
    let line = "[paseo-tray] \(message)"
    fputs(line + "\n", stderr)
    NSLog("%@", line)
}
