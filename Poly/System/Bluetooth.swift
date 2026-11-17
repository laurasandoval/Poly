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
    private var lastPairing: Task<Bool, Never>?
    /// Takes and forgets in progress. An update waits for none (`Updater`).
    private(set) var operations = 0

    /// Page timeouts, in 0.625 ms slots: about 5 seconds to connect, 2.5 to check an accessory answers.
    private let connectPageTimeout: BluetoothHCIPageTimeout = 0x1F40
    private let probePageTimeout: BluetoothHCIPageTimeout = 0x1000

    /// Accessories plugged in by cable, which Bluetooth calls disconnected (`Cables`).
    private let cables = Cables()

    func start() {
        guard connectNotification == nil else { return }
        connectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self, selector: #selector(deviceDidConnect(_:device:)))
        cables.onChange = { [weak self] in self?.cablesChanged() }
        onCable = cabledAddresses()
        cables.start()
    }

    /// Connected over Bluetooth, or plugged in by cable.
    func isConnected(_ address: String) -> Bool {
        device(address)?.isConnected() ?? false || isCabled(address)
    }
    func isPaired(_ address: String) -> Bool { device(address)?.isPaired() ?? false }
    func isCabled(_ address: String) -> Bool { cabledAddresses().contains(address) }

    /// Accessories on a cable: by the address macOS publishes for them or, for an Apple USB device
    /// without one, the single paired Apple accessory with the same product ID.
    /// Accessories on a cable at the last cable change, and when others left one.
    private var onCable: Set<String> = []
    private var leftCable: [String: Date] = [:]

    private func cablesChanged() {
        let now = cabledAddresses()
        for address in onCable.subtracting(now) {
            leftCable[address] = .now
            Log.bluetooth.info("\(address) left its cable")
        }
        for address in now.subtracting(onCable) { Log.bluetooth.info("\(address) is on a cable") }
        onCable = now
        onConnectionsChanged?()
    }

    private func cabledAddresses() -> Set<String> {
        let published = Cables.accessories()
        var result = Set(published.keys)
        let covered = Set(published.values.compactMap(\.productID))
        let unmatched = Cables.usbProductIDs().subtracting(covered)
        guard !unmatched.isEmpty else { return result }
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).compactMap(Self.accessoryInfo)
        for id in unmatched {
            let matches = paired.filter { $0.productID == id }
            if matches.count == 1 { result.insert(matches[0].address) }
        }
        return result
    }
    /// Paired with this Mac and not on a cable to it: one Poly may forget to let another Mac take it.
    func isReleasable(_ address: String) -> Bool { isPaired(address) && !isCabled(address) }

    /// Apple keyboards, mice and trackpads connected to this Mac right now, over Bluetooth or a cable.
    func connectedAccessories() -> [AccessoryInfo] {
        let devices = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let cabled = cabledAddresses()
        var found = devices.filter { device in
            device.isConnected() || device.addressString.map { cabled.contains(Self.normalized($0)) } ?? false
        }.compactMap(Self.accessoryInfo)
        for cabled in Cables.accessories().values where !found.contains(where: { $0.address == cabled.address }) {
            if let info = device(cabled.address).flatMap(Self.accessoryInfo) {
                found.append(info)
            } else if let kind = Self.kind(named: cabled.name) {
                // Not paired yet (or its records are not known): what the cable reports is enough.
                found.append(AccessoryInfo(address: cabled.address, name: cabled.name, kind: kind, productID: cabled.productID))
            }
        }
        return found
    }

    private static func kind(named name: String) -> Accessory.Kind? {
        if name.localizedCaseInsensitiveContains("Keyboard") { return .keyboard }
        if name.localizedCaseInsensitiveContains("Trackpad") { return .trackpad }
        if name.localizedCaseInsensitiveContains("Mouse") { return .mouse }
        return nil
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
        if device.isConnected() || isCabled(address) { return .connected }

        if device.isPaired() {
            let status = await openConnection(device)
            Log.bluetooth.info("\(address) bonded, connect: \(Log.hex(status))")
            if status == kIOReturnSuccess, await waitUntilConnected(device, seconds: 5) { return .connected }
            // The bond is stale (another Mac paired it since) or the accessory is away. Only re-pair
            // when it answers; forgetting a sleeping accessory gains nothing.
            let answer = await remoteNameRequest(device)
            Log.bluetooth.info("\(address) answer check: \(Log.hex(answer))")
            guard answer == kIOReturnSuccess else { return .unreachable }
            // Just off a cable, an accessory reconnects over Bluetooth by itself with the bond macOS
            // made through the cable; that bond is not stale. Let it, and look again later.
            if let off = leftCable[address], Date.now.timeIntervalSince(off) < 10 {
                Log.bluetooth.info("\(address) just left a cable; not re-pairing")
                return .unreachable
            }
            if device.isConnected() || isCabled(address) { return .connected }
            await forget(address)
            await pause(0.5)  // re-pairing inside the unbond window fails
            guard let fresh = self.device(address) else { return .failed }
            device = fresh
        } else {
            // Pairing something that is not listening hangs for a minute; ask first.
            let answer = await remoteNameRequest(device)
            Log.bluetooth.info("\(address) not bonded, answer check: \(Log.hex(answer))")
            guard answer == kIOReturnSuccess else { return .unreachable }
        }

        let paired = await pair(device, onConnected: onPaged)
        Log.bluetooth.info("\(address) pairing \(paired ? "succeeded" : "failed")")
        guard paired else { return .failed }
        if !device.isConnected() {
            let status = await openConnection(device)
            Log.bluetooth.info("\(address) connect after pairing: \(Log.hex(status))")
        }
        return await waitUntilConnected(device, seconds: 5) ? .connected : .failed
    }

    /// Forgets (unpairs) an accessory so another Mac can pair it. Apple accessories that are told
    /// they are unpaired go back to pairing mode by themselves.
    func forget(_ address: String) async {
        guard let device = device(address), device.isPaired() || device.isConnected() else { return }
        // On a cable it is in use right here; unpairing would only interrupt it.
        guard !isCabled(address) else {
            return Log.bluetooth.info("\(address) is on a cable; not forgetting")
        }
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
        Log.bluetooth.info("\(address) forgotten, still paired: \(device.isPaired())")
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
            await pause(0.25)
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

    /// Pairs one accessory at a time. When one pairing finishes, bluetoothd unregisters every
    /// pairing agent Poly has, so an overlapping pairing loses its agent and macOS asks the person
    /// instead ("Connection Request from: …"; Learnings, 2026-11-17).
    private func pair(
        _ device: IOBluetoothDevice, onConnected: @escaping () -> Void
    ) async -> Bool {
        let previous = lastPairing
        let box = UncheckedBox(device)
        let task = Task {
            _ = await previous?.value
            guard !Task.isCancelled else { return false }
            return await pairNow(box.value, onConnected: onConnected)
        }
        lastPairing = task
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Pairs, stopping early if the task is cancelled (the monitor was unplugged meanwhile).
    private func pairNow(
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

    // IOBluetooth can deliver these on its own queue (a crash on macOS 27 showed
    // com.apple.bluetooth.iobluetooth.coordinatorQueue), so they hop to the main actor first.
    @objc nonisolated private func deviceDidConnect(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        let device = UncheckedBox(device)
        onMainActor { self.connected(device.value) }
    }

    @objc nonisolated private func deviceDidDisconnect(
        _ notification: IOBluetoothUserNotification, device: IOBluetoothDevice
    ) {
        let both = UncheckedBox((notification, device))
        onMainActor { self.disconnected(both.value.0, both.value.1) }
    }

    private func connected(_ device: IOBluetoothDevice) {
        if let address = device.addressString.map(Self.normalized), disconnectNotifications[address] == nil {
            disconnectNotifications[address] = device.register(
                forDisconnectNotification: self, selector: #selector(deviceDidDisconnect(_:device:)))
        }
        onConnectionsChanged?()
    }

    private func disconnected(_ notification: IOBluetoothUserNotification, _ device: IOBluetoothDevice) {
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
            Log.bluetooth.error("pairing did not start: \(Log.hex(status))")
            return finish(false)
        }
        // `devicePairingConnected:` does not come when the answer check has just brought the link
        // up (first overlapped test), so the next accessory may also start shortly after this one.
        Task { @MainActor [weak self] in
            await pause(0.3)
            self?.onConnected()
        }
        // IOBluetoothDevicePair has no timeout of its own; a first handoff can take 30 to 45 seconds.
        Task { @MainActor [weak self] in
            await pause(60)
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

    // Delegate callbacks hop to the main actor too, in case IOBluetooth sends them from its queue.
    nonisolated func devicePairingStarted(_ sender: Any!) { Log.bluetooth.info("pairing started") }
    nonisolated func devicePairingConnecting(_ sender: Any!) { Log.bluetooth.info("pairing connecting") }

    /// Paging is done and the link is up; the rest of pairing (keys, encryption) runs on it.
    nonisolated func devicePairingConnected(_ sender: Any!) {
        Log.bluetooth.info("pairing connected")
        onMainActor { self.onConnected() }
    }

    nonisolated func devicePairingFinished(_ sender: Any!, error: IOReturn) {
        Log.bluetooth.info("pairing finished: \(Log.hex(error))")
        onMainActor { self.finish(error == kIOReturnSuccess) }
    }

    nonisolated func devicePairingUserConfirmationRequest(_ sender: Any!, numericValue: BluetoothNumericValue) {
        onMainActor { self.pair.replyUserConfirmation(true) }
    }

    nonisolated func devicePairingPINCodeRequest(_ sender: Any!) {
        onMainActor {
            var pin = BluetoothPINCode()
            withUnsafeMutableBytes(of: &pin.data) { bytes in
                for index in 0..<4 { bytes[index] = UInt8(ascii: "0") }
            }
            self.pair.replyPINCode(4, pinCode: &pin)
        }
    }

    nonisolated func devicePairingUserPasskeyNotification(_ sender: Any!, passkey: BluetoothPasskey) {
        Log.bluetooth.info("pairing asked to type a passkey")
    }
}

/// Hands the running pairing to the cancellation handler (a main-actor class, so it is Sendable).
private final class PairingSlot {
    var pairing: Pairing?
}

/// Runs `work` on the main actor: at once when already on the main thread, otherwise next.
nonisolated private func onMainActor(_ work: @escaping @MainActor @Sendable () -> Void) {
    if Thread.isMainThread {
        MainActor.assumeIsolated { work() }
    } else {
        DispatchQueue.main.async { work() }
    }
}

/// Carries a non-Sendable IOBluetooth object to the removal queue. Only that queue touches it
/// until the continuation resumes.
nonisolated private struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
