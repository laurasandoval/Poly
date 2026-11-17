import Foundation
import os

/// Poly's log. Every line goes to two places:
///
/// - The unified log (subsystem `work.lau.poly`, default level so macOS keeps it for days):
///
///       /usr/bin/log show --last 1h --predicate 'subsystem == "work.lau.poly"'
///
/// - Poly's own journal, `~/Library/Logs/Poly/Poly.log` (`Journal`), whose recent end is mirrored
///   to the person's iCloud so a Mac's history can be read from their other Macs
///   (`scripts/diagnostics.sh`).
///
/// Accessory addresses and monitor names are logged in full: they identify the person's own devices
/// on their own Mac and iCloud, and the log is useless for diagnosis without them. Nothing is sent
/// anywhere else.
nonisolated enum Log {
    static let app = LogChannel("app")
    static let switcher = LogChannel("switcher")
    static let bluetooth = LogChannel("bluetooth")
    static let updates = LogChannel("updates")

    static func hex(_ status: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: status))
    }
}

/// One log category. Messages are plain strings: everything in them is public (see `Log`).
nonisolated struct LogChannel: Sendable {
    private let category: String
    private let logger: Logger

    init(_ category: String) {
        self.category = category
        logger = Logger(subsystem: "work.lau.poly", category: category)
    }

    func info(_ message: String) {
        logger.log("\(message, privacy: .public)")
        Journal.shared.write(category, message)
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        Journal.shared.write(category, "error: " + message)
    }
}
