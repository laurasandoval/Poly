import AppKit
import UniformTypeIdentifiers

/// The pictures macOS itself uses for monitors and Apple accessories, sized for a menu. Nothing is
/// bundled: monitors come from the Displays override table and Finder's device types, accessories
/// from the artwork the system shows in its battery and connection notices.
enum SystemIcons {
    private static var cache: [String: NSImage] = [:]
    private static let menuSize = NSSize(width: 16, height: 16)

    static func monitor(vendorID: UInt32, productID: UInt32) -> NSImage {
        cached("monitor-\(vendorID)-\(productID)") {
            monitorIcon(vendorID: vendorID, productID: productID) ?? NSWorkspace.shared.icon(for: .init("public.display") ?? .item)
        }
    }

    static func accessory(_ accessory: Accessory) -> NSImage {
        let artwork = artworkName(accessory)
        return cached("accessory-\(artwork)") {
            let folders = [
                "/Library/Application Support/Apple/BezelServices/AppleTopCaseHIDEventDriver.plugin/Contents/Resources",
                "/System/Library/Templates/Data/Library/Application Support/Apple/BezelServices/AppleTopCaseHIDEventDriver.plugin/Contents/Resources",
            ]
            for folder in folders {
                if let image = NSImage(contentsOfFile: "\(folder)/\(artwork).icns") { return image }
            }
            let symbol =
                switch accessory.kind {
                case .keyboard: "keyboard"
                case .mouse: "magicmouse"
                case .trackpad: "rectangle.and.hand.point.up.left"
                }
            return NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage()
        }
    }

    private static func artworkName(_ accessory: Accessory) -> String {
        switch accessory.kind {
        case .mouse: return "Mouse"
        case .trackpad: return "MagicTrackpad"
        case .keyboard:
            // Product IDs do not say which keyboard variant this is reliably; the default names do.
            if accessory.name.localizedCaseInsensitiveContains("Numeric") { return "ExtendedKeyboard2" }
            if accessory.name.localizedCaseInsensitiveContains("Touch ID") { return "Keyboard3" }
            return "Keyboard2"
        }
    }

    /// The icon System Settings uses for this monitor model, from the Displays overrides table:
    /// vendors → hex vendor ID → products → hex product ID → "display-icon", which is a device type
    /// (com.apple.studio-display) or an image path.
    private static func monitorIcon(vendorID: UInt32, productID: UInt32) -> NSImage? {
        let table = URL(fileURLWithPath: "/System/Library/Displays/Contents/Resources/Overrides/Icons.plist")
        guard let plist = NSDictionary(contentsOf: table) as? [String: Any],
            let vendors = plist["vendors"] as? [String: Any],
            let vendor = vendors[String(vendorID, radix: 16)] as? [String: Any]
        else { return nil }
        let products = vendor["products"] as? [String: Any] ?? [:]
        let product = products.first { key, _ in
            let hex = key.lowercased().hasPrefix("0x") ? String(key.dropFirst(2)) : key
            return UInt32(hex, radix: 16) == productID
        }?.value as? [String: Any]
        guard let icon = product?["display-icon"] as? String ?? vendor["display-icon"] as? String else { return nil }
        if icon.hasPrefix("/") { return NSImage(contentsOfFile: icon) }
        guard let type = UTType(icon), type.isDeclared else { return nil }
        return NSWorkspace.shared.icon(for: type)
    }

    private static func cached(_ key: String, _ make: () -> NSImage) -> NSImage {
        if let image = cache[key] { return image }
        let image = (make().copy() as? NSImage) ?? NSImage()
        image.size = menuSize
        cache[key] = image
        return image
    }
}
