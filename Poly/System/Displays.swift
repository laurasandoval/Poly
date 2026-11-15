import AppKit
import IOKit

/// An external monitor plugged into this Mac right now.
struct AttachedMonitor: Hashable {
    /// "vendor-product-serial" in hex/plain text. Stable for one physical monitor on one Mac.
    let id: String
    let name: String
    let vendorID: UInt32
    let productID: UInt32
}

/// Which external monitors are plugged in. Built-in screens never count.
enum Displays {
    static func attached() -> [AttachedMonitor] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &displays, &count) == .success else { return [] }

        let names = screenNames()
        let panels = registryPanels()
        var seen = Set<String>()
        var monitors: [AttachedMonitor] = []
        for display in displays.prefix(Int(count)) where CGDisplayIsBuiltin(display) == 0 {
            let vendor = CGDisplayVendorNumber(display)
            let product = CGDisplayModelNumber(display)
            // The stand-in macOS lists while a closed MacBook has no lit display ('unkn' 'virt').
            if vendor == 0x756E_6B6E { continue }
            let matches = panels.filter { $0.vendorID == vendor && $0.productID == product }
            // Two Studio Displays (office, kitchen) differ only by serial number. The registry's
            // alphanumeric serial is the most distinctive; CoreGraphics' EDID serial is often 0.
            let serial = CGDisplaySerialNumber(display)
            let serialText: String =
                if matches.count == 1, let registrySerial = matches[0].serial {
                    registrySerial
                } else if serial != 0 {
                    String(serial)
                } else {
                    "0"
                }
            let id = String(format: "%x-%x-", vendor, product) + serialText
            guard seen.insert(id).inserted else { continue }  // mirrored outputs of one monitor
            let name = names[display] ?? matches.first?.name ?? String(localized: "Display")
            monitors.append(AttachedMonitor(id: id, name: name, vendorID: vendor, productID: product))
        }
        return monitors
    }

    private static func screenNames() -> [CGDirectDisplayID: String] {
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                names[number.uint32Value] = screen.localizedName
            }
        }
        return names
    }

    /// Known monitors the display controller reports even before macOS lists them (a closed
    /// MacBook that was just plugged in has its display off): matched by vendor, product and either
    /// registry serial against the saved identities.
    static func registryMatches(_ known: [Monitor]) -> [Monitor] {
        let candidates = Set(
            registryPanels().flatMap { panel in
                let prefix = String(format: "%x-%x-", panel.vendorID, panel.productID)
                return [panel.serial, panel.numericSerial, "0"].compactMap { $0 }.map { prefix + $0 }
            })
        return known.filter { candidates.contains($0.id) }
    }

    /// For the log: what the display controller reports right now.
    static func registrySummary() -> String {
        let panels = registryPanels().map { String(format: "%x-%x-", $0.vendorID, $0.productID) + ($0.serial ?? "?") }
        return panels.isEmpty ? "none" : panels.joined(separator: ", ")
    }

    private struct Panel {
        let vendorID: UInt32
        let productID: UInt32
        /// Alphanumeric serial when there is one, else the numeric one.
        let serial: String?
        let numericSerial: String?
        let name: String?
    }

    /// Panels the display controller reports, for their serial numbers (Apple silicon publishes
    /// `DisplayAttributes` on each framebuffer; elsewhere this is empty and CoreGraphics is used).
    private static func registryPanels() -> [Panel] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator)
            == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }

        var panels: [Panel] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard
                let attributes = IORegistryEntryCreateCFProperty(
                    service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any],
                let product = attributes["ProductAttributes"] as? [String: Any],
                let vendorID = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                let productID = (product["ProductID"] as? NSNumber)?.uint32Value
            else { continue }
            let alphanumeric = (product["AlphanumericSerialNumber"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let numeric = (product["SerialNumber"] as? NSNumber).flatMap { $0.uint32Value == 0 ? nil : $0.stringValue }
            panels.append(
                Panel(
                    vendorID: vendorID, productID: productID, serial: alphanumeric ?? numeric, numericSerial: numeric,
                    name: product["ProductName"] as? String))
        }
        return panels
    }
}
