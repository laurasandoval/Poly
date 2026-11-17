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
    /// Asked before an idle sleep; returning false cancels it.
    var mayIdleSleep: (() -> Bool)?

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
            if mayIdleSleep?() == false {
                IOCancelPowerChange(rootPort, argument)
            } else {
                IOAllowPowerChange(rootPort, argument)
            }
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

/// The MacBook lid, from the power manager's own state. More dependable than the display list in
/// the moment a closed MacBook is unplugged and starts to sleep. Macs without a lid report neither.
enum Lid {
    /// The lid is closed.
    static var isClosed: Bool { rootDomainFlag("AppleClamshellState") }

    /// A closed lid would put the Mac to sleep: no external display is keeping it awake. With the lid
    /// closed, false is the power manager saying a monitor is attached, even during the brief
    /// background wake of a closed MacBook being plugged in, when the display list does not show it
    /// yet. (True is not trustworthy at sleep time: it lags an unplug.)
    static var closingSleeps: Bool { rootDomainFlag("AppleClamshellCausesSleep") }

    private static func rootDomainFlag(_ key: String) -> Bool {
        let rootDomain = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard rootDomain != 0 else { return false }
        defer { IOObjectRelease(rootDomain) }
        let value = IORegistryEntryCreateCFProperty(rootDomain, key as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? Bool) ?? false
    }
}

/// Power assertions Poly takes while a monitor is plugged in.
final class Wakefulness {
    private var idleSleepAssertion: IOPMAssertionID = 0

    /// Keeps a closed MacBook from idle-sleeping while one of its monitors is plugged in; the display
    /// still sleeps. A closed MacBook then only sleeps when it is unplugged (or put to sleep on purpose),
    /// which is what lets Poly release everything whenever a closed MacBook sleeps. This assertion
    /// type does not stop lid or unplug sleep.
    func preventIdleSleep(_ prevent: Bool) {
        if prevent, idleSleepAssertion == 0 {
            let status = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Poly: a monitor with its keyboard and mouse is plugged in" as CFString, &idleSleepAssertion)
            Log.switcher.info("preventing idle sleep: \(status == kIOReturnSuccess)")
        } else if !prevent, idleSleepAssertion != 0 {
            IOPMAssertionRelease(idleSleepAssertion)
            idleSleepAssertion = 0
            Log.switcher.info("allowing idle sleep")
        }
    }

    /// Wakes the Mac fully (display on), as a key press would, so a closed MacBook that was just
    /// plugged in shows its lock screen while its keyboard connects.
    func wakeDisplay() {
        var assertion: IOPMAssertionID = 0
        let status = IOPMAssertionDeclareUserActivity(
            "Poly: connecting the monitor's keyboard and mouse" as CFString, kIOPMUserActiveLocal, &assertion)
        Log.switcher.info("waking the display: \(status == kIOReturnSuccess)")
    }
}
