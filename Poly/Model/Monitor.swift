import Foundation

/// A monitor Poly has seen this Mac plugged into, and the keyboards, mice and trackpads that belong
/// to it. Saved in UserDefaults; each Mac learns its own list.
struct Monitor: Codable, Identifiable, Hashable {
    /// Stable for one physical monitor on this Mac (`AttachedMonitor.id`).
    let id: String
    var name: String
    let vendorID: UInt32
    let productID: UInt32
    var accessories: [Accessory]
}

/// An Apple keyboard, mouse or trackpad that belongs to one monitor.
struct Accessory: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, Comparable {
        case keyboard, mouse, trackpad

        static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.order < rhs.order }
        private var order: Int {
            switch self {
            case .keyboard: 0
            case .mouse: 1
            case .trackpad: 2
            }
        }
    }

    /// Bluetooth address, lowercase with dashes ("68-fe-f7-51-10-68").
    let address: String
    /// The accessory's own name, as Bluetooth last reported it.
    var name: String
    /// A name the person chose while the accessory was not connected, given to the accessory the
    /// next time it connects.
    var pendingName: String?
    var kind: Kind
    var productID: UInt16?

    var id: String { address }
}

/// What the menu says about an accessory right now.
enum AccessoryStatus: Equatable {
    /// Connected to this Mac.
    case connected
    /// Its monitor is plugged in and Poly is connecting it.
    case connecting
    /// Poly has been trying for a while: the accessory is asleep or switched off.
    case needsNudge
    /// Its monitor is not plugged in, so another Mac may use it.
    case free
}
