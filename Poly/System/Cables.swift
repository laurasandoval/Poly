import Foundation
import IOKit

/// An Apple accessory on a cable to this Mac (directly or through a display's USB ports).
struct CabledAccessory {
    let address: String
    let name: String
    let productID: UInt16?
}

/// Apple keyboards, mice and trackpads plugged in by cable. On a cable they talk over USB, so
/// Bluetooth calls them disconnected; Poly must count them as connected, never try to take them
/// over Bluetooth (that path can unpair and re-pair them), and never forget them.
///
/// macOS publishes each one as an `AppleDeviceManagementHIDEventService` with `Transport` "USB",
/// `BluetoothDevice` true and the accessory's Bluetooth address in `DeviceAddress` (seen on macOS 27
/// with a Magic Keyboard and Magic Mouse; Learnings). Reading the registry needs no permission.
final class Cables {
    /// Called on the main actor when an Apple USB device appears or goes away.
    var onChange: (() -> Void)?
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    /// Accessories on a cable right now, by Bluetooth address.
    static func accessories() -> [String: CabledAccessory] {
        var found: [String: CabledAccessory] = [:]
        forEachService(matching: "AppleDeviceManagementHIDEventService") { service in
            guard property(service, "Transport") as? String == "USB",
                let address = property(service, "DeviceAddress") as? String
            else { return }
            let normalized = Bluetooth.normalized(address)
            found[normalized] = CabledAccessory(
                address: normalized,
                name: property(service, "Product") as? String ?? "",
                productID: (property(service, "ProductID") as? NSNumber)?.uint16Value)
        }
        return found
    }

    /// Product IDs of Apple HID devices on USB. A Magic accessory has the same product ID over USB
    /// and Bluetooth (801 and 617 for the owner's keyboard and mouse), which identifies it where
    /// macOS does not publish its address (possibly older macOS).
    static func usbProductIDs() -> Set<UInt16> {
        var found = Set<UInt16>()
        forEachService(matching: "IOHIDDevice") { service in
            guard property(service, "Transport") as? String == "USB",
                (property(service, "VendorID") as? NSNumber)?.intValue == 0x05AC,
                let id = (property(service, "ProductID") as? NSNumber)?.uint16Value
            else { return }
            found.insert(id)
        }
        return found
    }

    /// Watches for Apple USB HID devices coming and going.
    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let context = Unmanaged.passUnretained(self).toOpaque()
        for (className, type) in [
            ("AppleDeviceManagementHIDEventService", kIOFirstMatchNotification),
            ("AppleDeviceManagementHIDEventService", kIOTerminatedNotification),
            ("IOHIDDevice", kIOFirstMatchNotification), ("IOHIDDevice", kIOTerminatedNotification),
        ] {
            guard let matching = IOServiceMatching(className) else { continue }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, type, matching, cablesChanged, context, &iterator)
            guard result == KERN_SUCCESS else { continue }
            drain(iterator)  // arms the notification
            iterators.append(iterator)
        }
    }

    fileprivate func changed(_ iterator: io_iterator_t) {
        drain(iterator)
        onChange?()
    }

    private func drain(_ iterator: io_iterator_t) {
        var service = IOIteratorNext(iterator)
        while service != 0 {
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func forEachService(matching className: String, _ body: (io_service_t) -> Void) {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(className), &iterator) == KERN_SUCCESS
        else { return }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            body(service)
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
    }

    private static func property(_ service: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}

/// IOKit calls this on the main run loop, where the notification port's source was added.
nonisolated private func cablesChanged(_ context: UnsafeMutableRawPointer?, _ iterator: io_iterator_t) {
    guard let context else { return }
    nonisolated(unsafe) let pointer = context
    MainActor.assumeIsolated {
        Unmanaged<Cables>.fromOpaque(pointer).takeUnretainedValue().changed(iterator)
    }
}
