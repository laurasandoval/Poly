import Foundation
import IOKit.pwr_mgt

/// System sleep and wake. Before sleeping, macOS waits (up to about 30 seconds) for every app that
/// registered here to allow it, which gives Poly time to forget accessories when a closed MacBook is
/// unplugged from its monitor and goes straight to sleep.
final class PowerEvents {
    /// Called before the system sleeps. Call `done` when ready; sleep waits for it.
    var willSleep: ((_ done: @escaping () -> Void) -> Void)?
    /// Called after waking, or when a sleep that was announced did not happen.
    var didWake: (() -> Void)?

    private var rootPort: io_connect_t = 0
    private var notifier: io_object_t = 0
    private var notificationPort: IONotificationPortRef?

    // iokit_common_msg(...) from IOMessage.h; the macros are not imported into Swift.
    private static let canSystemSleep: UInt32 = 0xE000_0270
    private static let systemWillSleep: UInt32 = 0xE000_0280
    private static let systemWillNotSleep: UInt32 = 0xE000_0290
    private static let systemHasPoweredOn: UInt32 = 0xE000_0300

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(context, &notificationPort, powerCallback, &notifier)
        guard rootPort != 0, let notificationPort else { return }
        CFRunLoopAddSource(
            CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notificationPort).takeUnretainedValue(),
            .commonModes)
    }

    fileprivate func handle(_ message: UInt32, argument: Int) {
        switch message {
        case Self.canSystemSleep:
            IOAllowPowerChange(rootPort, argument)
        case Self.systemWillSleep:
            guard let willSleep else {
                IOAllowPowerChange(rootPort, argument)
                return
            }
            var allowed = false
            let rootPort = rootPort
            willSleep {
                guard !allowed else { return }
                allowed = true
                IOAllowPowerChange(rootPort, argument)
            }
        case Self.systemHasPoweredOn, Self.systemWillNotSleep:
            didWake?()
        default:
            break
        }
    }
}

/// Runs on the main run loop, where `start()` added the notification source.
nonisolated private func powerCallback(
    context: UnsafeMutableRawPointer?, service: io_service_t, message: UInt32, argument: UnsafeMutableRawPointer?
) {
    // Pointers are not Sendable; carry them as integers into the main actor.
    let owner = Int(bitPattern: context)
    let argument = Int(bitPattern: argument)
    MainActor.assumeIsolated {
        guard let context = UnsafeMutableRawPointer(bitPattern: owner) else { return }
        Unmanaged<PowerEvents>.fromOpaque(context).takeUnretainedValue().handle(message, argument: argument)
    }
}
