import Foundation
import os

/// Poly's unified log. To see what happened on a Mac:
///
///     log show --last 1h --info --predicate 'subsystem == "work.lau.poly"'
///
/// Accessory addresses and monitor names are public: they identify the person's own devices on
/// their own Mac, and the log is useless for diagnosis without them.
nonisolated enum Log {
    static let switcher = Logger(subsystem: "work.lau.poly", category: "switcher")
    static let bluetooth = Logger(subsystem: "work.lau.poly", category: "bluetooth")
    static let updates = Logger(subsystem: "work.lau.poly", category: "updates")

    static func hex(_ status: IOReturn) -> String {
        String(format: "0x%08x", UInt32(bitPattern: status))
    }
}
