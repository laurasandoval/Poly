import Foundation
import IOBluetooth
import os

/// An Apple keyboard, mouse or trackpad as Bluetooth sees it.
struct AccessoryInfo: Hashable {
    let address: String
    let name: String
    let kind: Accessory.Kind
    let productID: UInt16?
}

/// How taking an accessory ended.
enum TakeResult {
    case connected
    /// It did not answer: asleep, switched off, out of range or busy with another Mac.
    case unreachable
    case failed
}

/// Pairs, connects and forgets accessories with IOBluetooth.
///
/// The sequence follows what proved reliable in Magic Switch and blueutil: the Mac giving an
/// accessory up only forgets it (Apple accessories then go back to pairing mode); the Mac taking it
/// connects if it still holds a bond, and otherwise checks the accessory answers before pairing,
/// connecting once pairing finishes.
///
/// Connecting, the answer check and forgetting use IOBluetooth's synchronous calls (no target),
/// as blueutil and Magic Switch do, on one serial queue so the main thread never waits. The
/// asynchronous variants call back through selectors that differ between methods and are easy to
/// get wrong silently (see Documentation/Learnings.md). Pairing needs the main run loop for its
/// delegate callbacks.
final class Bluetooth: NSObject {
    /// Called on the main actor whenever any device connects or disconnects.
    var onConnectionsChanged: (() -> Void)?

    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [String: IOBluetoothUserNotification] = [:]
    /// Synchronous IOBluetooth calls are IPC to bluetoothd that can take seconds.
    private let queue = DispatchQueue(label: "work.lau.poly.bluetooth")
    /// Pairings in progress, kept alive until they finish.
    private var pending: Set<NSObject> = []
    /// Takes and forgets in progress. An update waits for none (`Updater`).
    private(set) var operations = 0

    /// Page timeouts, in 0.625 ms slots: about 5 seconds to connect, 2.5 to check an accessory answers.
    private let connectPageTimeout: BluetoothHCIPageTimeout = 0x1F40
    private let probePageTimeout: BluetoothHCIPageTimeout = 0x1000

    func start() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceDidConnect(_:device:)))
    }

    func isConnected(_ address: String) -> Bool { device(address)?.isConnected() ?? false }
    func isPaired(_ address: String) -> Bool { device(address)?.isPaired() ?? false }

    /// Apple keyboards, mice and trackpads connected to this Mac right now.
    func connectedAccessories() -> [AccessoryInfo] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        return devices.filter { $0.isConnected() }.compactMap(Self.accessoryInfo)
    }

    // MARK: Taking and releasing

    /// Connects an accessory to this Mac, pairing it first when this Mac holds no bond.
    /// `onPaged` runs once the radio link is up (or the attempt ended), when the controller is free
    /// to page the next accessory while this one finishes pairing.
    func take(
        _ address: String, onPaged: @escaping () -> Void = {}
    ) async -> TakeResult {
        operations += 1
        defer {
            operations -= 1
            onPaged()
        }
        guard var device = device(address) else { return .failed }
        if device.isConnected() { return .connected }

        if device.isPaired() {
            let status = await openConnection(device)
            Log.bluetooth.info("\(address, privacy: .public) bonded, connect: \(Log.hex(status), privacy: .public)")
            if status == kIOReturnSuccess, await waitUntilConnected(device, seconds: 5) { return .connected }
            // The bond is stale (another Mac paired it since) or the accessory is away. Only re-pair
            // when it answers; forgetting a sleeping accessory gains nothing.
            let answer = await remoteNameRequest(device)
            Log.bluetooth.info("\(address, privacy: .public) answer check: \(Log.hex(answer), privacy: .public)")
            guard answer == kIOReturnSuccess else { return .unreachable }
            await forget(address)
            try? await Task.sleep(for: .milliseconds(500))  // re-pairing inside the unbond window fails
            guard let fresh = self.device(address) else { return .failed }
            device = fresh
        } else {
            // Pairing something that is not listening hangs for a minute; ask first.
            let answer = await remoteNameRequest(device)
            Log.bluetooth.info("\(address, privacy: .public) not bonded, answer check: \(Log.hex(answer), privacy: .public)")
            guard answer == kIOReturnSuccess else { return .unreachable }
        }

        let paired = await pair(device, onConnected: onPaged)
        Log.bluetooth.info("\(address, privacy: .public) pairing \(paired ? "succeeded" : "failed", privacy: .public)")
        guard paired else { return .failed }
        if !device.isConnected() {
            let status = await openConnection(device)
            Log.bluetooth.info("\(address, privacy: .public) connect after pairing: \(Log.hex(status), privacy: .public)")
        }
        return await waitUntilConnected(device, seconds: 5) ? .connected : .failed
    }

    /// Forgets (unpairs) an accessory so another Mac can pair it. Apple accessories that are told
    /// they are unpaired go back to pairing mode by themselves.
    func forget(_ address: String) async {
        guard let device = device(address), device.isPaired() || device.isConnected() else { return }
        operations += 1
        defer { operations -= 1 }
        let box = UncheckedBox(device)
        await onQueue {
            let remove = Selector(("remove"))
            if box.value.responds(to: remove) {
                _ = box.value.perform(remove)
            } else {
                box.value.closeConnection()
            }
        }
        Log.bluetooth.info("\(address, privacy: .public) forgotten, still paired: \(device.isPaired(), privacy: .public)")
    }

    /// Renames an accessory the way Bluetooth settings' Name field does, through IOBluetoothDevice's
    /// private `rename:`. Returns the name Bluetooth reports afterwards.
    func rename(_ address: String, to name: String) async -> String? {
        guard let device = device(address) else { return nil }
        let box = UncheckedBox(device)
        await onQueue {
            let rename = Selector(("rename:"))
            if box.value.responds(to: rename) { _ = box.value.perform(rename, with: name) }
        }
        let reported = device.name
        Log.bluetooth.info(
            "\(address, privacy: .public) renamed to \(name, privacy: .public), reports \(reported ?? "nothing", privacy: .public)")
        return reported
    }

    // MARK: IOBluetooth plumbing

    private func device(_ address: String) -> IOBluetoothDevice? { IOBluetoothDevice(addressString: address) }

    private func waitUntilConnected(_ device: IOBluetoothDevice, seconds: Double) async -> Bool {
        let deadline = Date.now.addingTimeInterval(seconds)
        while !device.isConnected() {
            guard Date.now < deadline, !Task.isCancelled else { return false }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return true
    }

    /// Opens a connection that must authenticate, so a stale bond fails here instead of
    /// connecting for a moment and dropping when the accessory rejects the old key.
    private func openConnection(_ device: IOBluetoothDevice) async -> IOReturn {
        let box = UncheckedBox(device)
        let timeout = connectPageTimeout
        return await onQueue { box.value.openConnection(nil, withPageTimeout: timeout, authenticationRequired: true) }
    }

    /// Whether the accessory answers at all: listening, awake and in range.
    private func remoteNameRequest(_ device: IOBluetoothDevice) async -> IOReturn {
        let box = UncheckedBox(device)
        let timeout = probePageTimeout
        return await onQueue { box.value.remoteNameRequest(nil, withPageTimeout: timeout) }
    }

    /// Runs a synchronous IOBluetooth call on the serial Bluetooth queue.
    private func onQueue<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let queue = queue
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Pairs, stopping early if the task is cancelled (the monitor was unplugged meanwhile).
    private func pair(
        _ device: IOBluetoothDevice, onConnected: @escaping () -> Void
    ) async -> Bool {
        let slot = PairingSlot()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let attempt = Pairing(device: device, onConnected: onConnected) {
                    [weak self] pairing, success in
                    self?.pending.remove(pairing)
                    continuation.resume(returning: success)
                }
                slot.pairing = attempt
                pending.insert(attempt)
                attempt.start()
            }
        } onCancel: {
            Task { @MainActor in slot.pairing?.cancel() }
        }
    }

    @objc private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        if let address = device.addressString.map(Self.normalized), disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDidDisconnect(_:device:)))
        }
        onConnectionsChanged?()
    }

    @objc private func deviceDidDisconnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        notification.unregister()
        if let address = device.addressString.map(Self.normalized) { disconnectNotifications[address] = nil }
        onConnectionsChanged?()
    }

    // MARK: Recognizing accessories

    static func normalized(_ address: String) -> String {
        address.lowercased().replacingOccurrences(of: ":", with: "-")
    }

    /// The accessory a device is, or nil for anything that is not an Apple keyboard, mouse or trackpad.
    static func accessoryInfo(_ device: IOBluetoothDevice) -> AccessoryInfo? {
        guard device.deviceClassMajor == BluetoothDeviceClassMajor(kBluetoothDeviceClassMajorPeripheral),
            let address = device.addressString
        else { return nil }
        let name = device.name ?? ""
        let (vendorID, productID) = deviceID(device)
        let isApple = vendorID.map { $0 == 0x004C || $0 == 0x05AC } ?? name.localizedCaseInsensitiveContains("Magic")
        guard isApple else { return nil }

        let kind: Accessory.Kind
        switch device.deviceClassMinor & 0x30 {
        case 0x10, 0x30:
            kind = .keyboard
        case 0x20:
            let trackpadIDs: Set<UInt16> = [0x030E, 0x0265, 0x0314, 0x0324]
            let isTrackpad = productID.map(trackpadIDs.contains) ?? false
            kind = isTrackpad || name.localizedCaseInsensitiveContains("Trackpad") ? .trackpad : .mouse
        default:
            return nil
        }
        return AccessoryInfo(address: normalized(address), name: name, kind: kind, productID: productID)
    }

    /// Vendor and product IDs from the device's Device ID (PnP Information) service record.
    private static func deviceID(_ device: IOBluetoothDevice) -> (vendor: UInt16?, product: UInt16?) {
        let uuid = IOBluetoothSDPUUID(uuid16: 0x1200)  // PnP Information
        guard let record = device.getServiceRecord(for: uuid) else { return (nil, nil) }
        func value(_ attribute: Int) -> UInt16? {
            record.getAttributeDataElement(BluetoothSDPServiceAttributeID(attribute))?.getNumberValue()?.uint16Value
        }
        return (value(0x0201), value(0x0202))
    }
}

/// One pairing attempt. Confirms numeric comparison, answers legacy PIN requests with 0000 (keyless
/// accessories). A keyboard asking for a passkey is only logged: Magic Keyboards have not been
/// seen to ask, and macOS shows its own prompt when one does.
private final class Pairing: NSObject, IOBluetoothDevicePairDelegate {
    private let pair: IOBluetoothDevicePair
    private let onConnected: () -> Void
    private var handler: ((Pairing, Bool) -> Void)?

    init(
        device: IOBluetoothDevice, onConnected: @escaping () -> Void,
        handler: @escaping (Pairing, Bool) -> Void
    ) {
        self.onConnected = onConnected
        pair = IOBluetoothDevicePair(device: device)
        self.handler = handler
        super.init()
        pair.delegate = self
    }

    func start() {
        let status = pair.start()
        guard status == kIOReturnSuccess else {
            Log.bluetooth.error("pairing did not start: \(Log.hex(status), privacy: .public)")
            return finish(false)
        }
        // `devicePairingConnected:` does not come when the answer check has just brought the link
        // up (first overlapped test), so the next accessory may also start shortly after this one.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.onConnected()
        }
        // IOBluetoothDevicePair has no timeout of its own; a first handoff can take 30 to 45 seconds.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(60))
            self?.cancel()
        }
    }

    func cancel() {
        guard handler != nil else { return }
        Log.bluetooth.info("pairing stopped")
        pair.stop()
        finish(false)
    }

    private func finish(_ success: Bool) {
        guard let handler else { return }
        self.handler = nil
        pair.delegate = nil
        handler(self, success)
    }

    func devicePairingStarted(_ sender: Any!) { Log.bluetooth.info("pairing started") }
    func devicePairingConnecting(_ sender: Any!) { Log.bluetooth.info("pairing connecting") }

    /// Paging is done and the link is up; the rest of pairing (keys, encryption) runs on it.
    func devicePairingConnected(_ sender: Any!) {
        Log.bluetooth.info("pairing connected")
        onConnected()
    }

    func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        Log.bluetooth.info("pairing finished: \(Log.hex(error), privacy: .public)")
        finish(error == kIOReturnSuccess)
    }

    func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        pair.replyUserConfirmation(true)
    }

    func devicePairingPINCodeRequest(_ sender: Any!) {
        var pin = BluetoothPINCode()
        withUnsafeMutableBytes(of: &pin.data) { bytes in
            for index in 0..<4 { bytes[index] = UInt8(ascii: "0") }
        }
        pair.replyPINCode(4, pinCode: &pin)
    }

    func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        Log.bluetooth.info("pairing asked to type a passkey")
    }
}

/// Hands the running pairing to the cancellation handler (a main-actor class, so it is Sendable).
private final class PairingSlot {
    var pairing: Pairing?
}

/// Carries a non-Sendable IOBluetooth object to the removal queue. Only that queue touches it
/// until the continuation resumes.
nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
