import Foundation
import os

/// No plaintext log next to recordings. Opt-in diagnostics use macOS unified
/// logging with private fields and OS-managed retention.
enum Log {
    private static let logger = Logger(subsystem: "com.local.meetrec", category: "diagnostics")

    static func write(_ message: String) {
        guard UserDefaults.standard.bool(forKey: "DiagnosticsEnabled") else { return }
        logger.debug("\(message, privacy: .private)")
    }

    static func reset() { write("session start") }
}
