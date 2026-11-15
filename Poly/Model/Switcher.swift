import AppKit
import CoreBluetooth
import Observation
import os

/// Poly's whole behavior: a monitor's accessories follow the Mac plugged into it.
///
/// - **Plugged in** → connect that monitor's accessories, pairing them when needed.
/// - **Unplugged** → forget them (after a short grace period) so the next Mac can pair them.
/// - **About to sleep** (a closed MacBook unplugged from its monitor sleeps at once) → forget the
///   accessories of monitors that are gone before allowing sleep.
/// - **Learning** → an Apple keyboard, mouse or trackpad that connects while exactly one monitor
///   is plugged in belongs to that monitor from then on.
///
/// Every trigger runs `reconcile()`, which compares what is plugged in with what this Mac holds, so
/// a missed event is repaired by the next one. Everything runs on the main actor.
@Observable
final class Switcher {
    enum BluetoothState { case waiting, ready, off, denied }

    private(set) var monitors: [Monitor] = [] {
        didSet { save() }
    }
    private(set) var attachedMonitors: [AttachedMonitor] = []
    private(set) var bluetoothState: BluetoothState = .waiting
    /// Accessory addresses connected to this Mac, refreshed on every Bluetooth connection change.
    private(set) var connected: Set<String> = []
    /// Accessories Poly has been trying to reach for a while.
    private(set) var needsNudge: Set<String> = []

    @ObservationIgnored private let bluetooth = Bluetooth()
    @ObservationIgnored private let access = BluetoothAccess()
    @ObservationIgnored private let power = PowerEvents()
    @ObservationIgnored private let wakefulness = Wakefulness()
    /// One running claim per plugged-in monitor. The token lets a cancelled claim that finishes late
    /// tell that a newer claim has replaced it.
    @ObservationIgnored private var claims: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var releases: [String: Task<Void, Never>] = [:]
    /// When each unplugged monitor whose accessories this Mac still holds went missing.
    @ObservationIgnored private var missingSince: [String: Date] = [:]
    /// Displays take a few seconds to come back after login or wake; nothing is released before this.
    @ObservationIgnored private var holdReleasesUntil = Date.now.addingTimeInterval(15)
    /// Right after a wake the display list can still show the monitor from before the sleep; no
    /// claims until it has had a moment to catch up, or Poly could pair accessories another Mac uses.
    @ObservationIgnored private var holdClaimsUntil = Date.distantPast
    @ObservationIgnored private var reconcileSoonPending = false
    @ObservationIgnored private var sleeping = false

    private static let storageKey = "monitors"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode([Monitor].self, from: data)
        {
            monitors = saved
        }
    }

    func start() {
        access.onChange = { [weak self] in self?.bluetoothAccessChanged() }
        access.start()

        bluetooth.onConnectionsChanged = { [weak self] in self?.reconcileSoon() }
        power.willSleep = { [weak self] done in
            guard let self else { return done() }
            Task {
                await self.prepareForSleep()
                done()
            }
        }
        power.didWake = { [weak self] in self?.didWake() }
        power.mayIdleSleep = { [weak self] in
            guard let self, isClosedOnMonitor else { return true }
            Log.switcher.info("closed on a monitor: cancelling idle sleep")
            wakefulness.wakeDisplay()
            return false
        }
        power.start()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
    }

    // MARK: What the menu shows

    func isAttached(_ monitor: Monitor) -> Bool { attachedMonitors.contains { $0.id == monitor.id } }

    func status(of accessory: Accessory, on monitor: Monitor) -> AccessoryStatus {
        if connected.contains(accessory.address) { return .connected }
        guard isAttached(monitor) else { return .free }
        return needsNudge.contains(accessory.address) ? .needsNudge : .connecting
    }

    /// A closed MacBook with a monitor plugged in, per the power manager, on a Mac that has learned
    /// at least one monitor.
    private var isClosedOnMonitor: Bool {
        !monitors.isEmpty && Lid.isClosed && !Lid.closingSleeps
    }

    var needsAttention: Bool {
        bluetoothState == .denied || bluetoothState == .off || !needsNudge.isEmpty
    }

    /// Stops managing an accessory and unpairs it from this Mac, like Bluetooth settings' "Forget".
    /// Unpairing is what keeps Poly from learning it again the moment it reconnects; connecting it
    /// again while a monitor is plugged in teaches Poly about it again.
    func forget(_ accessory: Accessory) {
        var updated = monitors
        for index in updated.indices { updated[index].accessories.removeAll { $0.address == accessory.address } }
        updated.removeAll { $0.accessories.isEmpty }
        monitors = updated
        needsNudge.remove(accessory.address)
        Notifier.clearNudge(for: accessory)
        Task { await bluetooth.forget(accessory.address) }
    }

    /// Removes an unplugged monitor Poly no longer needs to remember.
    func forget(_ monitor: Monitor) {
        guard !isAttached(monitor) else { return }
        monitors.removeAll { $0.id == monitor.id }
        missingSince[monitor.id] = nil
    }

    // MARK: Triggers

    private func bluetoothAccessChanged() {
        bluetoothState = access.state
        if bluetoothState == .ready {
            bluetooth.start()
            reconcile()
        } else {
            for monitorID in Array(claims.keys) { stopClaim(monitorID) }
        }
    }

    private func displaysChanged() {
        reconcile()
        // A monitor's registry details can land a moment after CoreGraphics reports it.
        reconcile(after: 2)
    }

    /// Checks right away and then every 2 s for half a minute: after a wake (including the
    /// background wake of a closed MacBook being plugged in) the monitor can take a while to show up.
    private func didWake() {
        Log.switcher.info(
            "woke; lid closed: \(Lid.isClosed, privacy: .public), lid sleeps: \(Lid.closingSleeps, privacy: .public)")
        sleeping = false
        holdReleasesUntil = .now.addingTimeInterval(15)
        holdClaimsUntil = .now.addingTimeInterval(1.5)
        // Plugging a closed MacBook into a monitor wakes it for only a second or so, in the
        // background, with the display still off and missing from the display list. Wake it fully,
        // as a key press would, so the display lights up and its accessories can connect.
        if isClosedOnMonitor { wakefulness.wakeDisplay() }
        reconcile()
        for second in stride(from: 2.0, through: 30, by: 2) { reconcile(after: second) }
    }

    /// The monitor a closed MacBook was just plugged into, before macOS lists it (about 1.6 s after
    /// the wake): the known monitor the display controller already reports, or, when this Mac knows
    /// only one monitor, that one. With several known and none reported, nothing is guessed: taking
    /// another monitor's accessories would take them from whoever is using them.
    private func inferredMonitors() -> [AttachedMonitor] {
        var matches = Displays.registryMatches(monitors)
        if matches.isEmpty, monitors.count == 1 { matches = monitors }
        Log.switcher.info(
            "closed on a monitor not listed yet; registry: \(Displays.registrySummary(), privacy: .public), inferred: \(matches.map(\.name).joined(separator: ", "), privacy: .public)"
        )
        return matches.map {
            AttachedMonitor(id: $0.id, name: $0.name, vendorID: $0.vendorID, productID: $0.productID)
        }
    }

    /// Coalesces bursts of Bluetooth notifications into one pass.
    private func reconcileSoon() {
        guard !reconcileSoonPending else { return }
        reconcileSoonPending = true
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            reconcileSoonPending = false
            reconcile()
        }
    }

    private func reconcile(after seconds: Double) {
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            reconcile()
        }
    }

    // MARK: Reconcile

    private func reconcile() {
        guard bluetoothState == .ready, !sleeping else { return }
        var attached = Displays.attached()
        let closedOnMonitor = isClosedOnMonitor
        // Only while macOS lists no real display yet: once it lists one, that list is the truth.
        if closedOnMonitor, attached.isEmpty { attached = inferredMonitors() }
        let newlyAttached = Set(attached.map(\.id)).subtracting(attachedMonitors.map(\.id))
        if attached != attachedMonitors {
            let names = attached.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
            Log.switcher.info("monitors attached: \(names.isEmpty ? "none" : names, privacy: .public)")
            attachedMonitors = attached
        }
        refreshConnected()

        let attachedIDs = Set(attachedMonitors.map(\.id))
        for monitor in monitors where !attachedIDs.contains(monitor.id) {
            stopClaim(monitor.id)
            for accessory in monitor.accessories { needsNudge.remove(accessory.address) }
            considerReleasing(monitor)
        }

        for info in bluetooth.connectedAccessories() { learn(info) }

        let attachedKnown = monitors.filter { attachedIDs.contains($0.id) }
        // Only a closed MacBook needs this (see Wakefulness); closing or opening the lid changes the
        // screens, which runs reconcile again.
        wakefulness.preventIdleSleep(!attachedKnown.isEmpty && Lid.isClosed)
        // A closed MacBook just plugged in may still have its display off: light it, as a key press
        // would, so the lock screen is there when the keyboard connects.
        if Lid.isClosed, attachedKnown.contains(where: { newlyAttached.contains($0.id) }) {
            wakefulness.wakeDisplay()
        }
        // The hold guards against a display list left over from before a sleep; the power manager
        // saying a closed MacBook has a monitor is current, so it needs no hold.
        let claimsHeld = holdClaimsUntil > .now && !closedOnMonitor
        if claimsHeld { reconcile(after: holdClaimsUntil.timeIntervalSinceNow + 0.1) }
        for monitor in attachedKnown {
            missingSince[monitor.id] = nil
            if !claimsHeld, monitor.accessories.contains(where: { !connected.contains($0.address) }) {
                startClaim(monitor.id)
            }
        }
    }

    /// Forgets a missing monitor's accessories once it has been gone for a moment, so a flaky cable
    /// or a slow wake does not hand them away.
    private func considerReleasing(_ monitor: Monitor) {
        guard releases[monitor.id] == nil else { return }
        guard monitor.accessories.contains(where: { bluetooth.isPaired($0.address) }) else {
            missingSince[monitor.id] = nil
            return
        }
        let since = missingSince[monitor.id] ?? .now
        missingSince[monitor.id] = since
        // Closed and about to sleep for lack of a monitor: no time for a grace period.
        let sleepingSoon = Lid.isClosed && Lid.closingSleeps
        let releaseAt = sleepingSoon ? .now : max(since.addingTimeInterval(2), holdReleasesUntil)
        guard releaseAt <= .now else { return reconcile(after: releaseAt.timeIntervalSinceNow + 0.1) }
        Log.switcher.info("releasing accessories of \(monitor.name, privacy: .public) [\(monitor.id, privacy: .public)]")
        releases[monitor.id] = Task {
            await release(monitor.id)
            releases[monitor.id] = nil
            missingSince[monitor.id] = nil
        }
    }

    // MARK: Claiming and releasing

    private func startClaim(_ monitorID: String) {
        guard claims[monitorID] == nil else { return }
        let token = UUID()
        let task = Task {
            await claim(monitorID)
            if claims[monitorID]?.token == token { claims[monitorID] = nil }
        }
        claims[monitorID] = (token, task)
    }

    private func stopClaim(_ monitorID: String) {
        claims.removeValue(forKey: monitorID)?.task.cancel()
    }

    /// Connects a plugged-in monitor's accessories, retrying until all are connected or the monitor
    /// is unplugged. Retries come quickly at first, so a click on a sleeping mouse connects it in
    /// seconds, and slow down after a few minutes. After 20 seconds an accessory that has not
    /// answered is probably asleep or off, and the person gets a nudge.
    private func claim(_ monitorID: String) async {
        await releases[monitorID]?.value
        let started = Date.now
        while !Task.isCancelled, !sleeping, let monitor = monitors.first(where: { $0.id == monitorID }) {
            let waiting = monitor.accessories.filter { !bluetooth.isConnected($0.address) }
            if waiting.isEmpty { break }
            for accessory in waiting {
                if Task.isCancelled { break }
                let result = await bluetooth.take(accessory.address) { passkey in
                    Notifier.typePasskey(passkey, on: accessory)
                }
                Log.switcher.info("take \(accessory.name, privacy: .public): \(String(describing: result), privacy: .public)")
                refreshConnected()
                if result == .connected {
                    needsNudge.remove(accessory.address)
                    Notifier.clearNudge(for: accessory)
                } else if Date.now.timeIntervalSince(started) > 20, !needsNudge.contains(accessory.address) {
                    needsNudge.insert(accessory.address)
                    Notifier.nudge(accessory)
                }
            }
            let elapsed = Date.now.timeIntervalSince(started)
            try? await Task.sleep(for: .seconds(elapsed < 120 ? 1 : elapsed < 600 ? 5 : 20))
        }
    }

    private func release(_ monitorID: String) async {
        guard let monitor = monitors.first(where: { $0.id == monitorID }) else { return }
        for accessory in monitor.accessories where bluetooth.isPaired(accessory.address) {
            await bluetooth.forget(accessory.address)
        }
        refreshConnected()
    }

    /// Lets go of the accessories of monitors that are gone, then lets the Mac sleep. macOS holds
    /// sleep for this, up to about 30 seconds, so the work stops after 20.
    private func prepareForSleep() async {
        sleeping = true
        for monitorID in Array(claims.keys) { stopClaim(monitorID) }
        guard bluetoothState == .ready else { return }

        let work = Task {
            // Poly keeps the Mac from idle-sleeping while a monitor is plugged in, so a closed
            // MacBook that sleeps was unplugged (or put to sleep on purpose): let go of everything.
            // The display list cannot be trusted here: it still lists a monitor unplugged a second
            // ago (Documentation/Learnings.md). With the lid open, it is all there is.
            let lidClosed = Lid.isClosed
            if !lidClosed { try? await Task.sleep(for: .seconds(1)) }
            let listed = Set(Displays.attached().map(\.id))
            let attachedIDs: Set<String> = lidClosed ? [] : listed
            Log.switcher.info(
                "about to sleep; lid closed: \(lidClosed, privacy: .public), lid sleeps: \(Lid.closingSleeps, privacy: .public), listed: \(listed.sorted().joined(separator: ", "), privacy: .public)"
            )
            for monitor in monitors where !attachedIDs.contains(monitor.id) {
                if Task.isCancelled { return }
                await releases[monitor.id]?.value
                await release(monitor.id)
            }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(20))
            work.cancel()
        }
        await work.value
        deadline.cancel()
    }

    // MARK: Learning

    /// Also clears nudges for anything that connected, however it connected (by Poly, or by hand).
    private func refreshConnected() {
        let now = Set(bluetooth.connectedAccessories().map(\.address))
        if now != connected { connected = now }
        let nudged = needsNudge.intersection(now)
        guard !nudged.isEmpty else { return }
        needsNudge.subtract(nudged)
        for monitor in monitors {
            for accessory in monitor.accessories where nudged.contains(accessory.address) {
                Notifier.clearNudge(for: accessory)
            }
        }
    }

    /// Records that a connected accessory belongs to the monitor plugged in now. Nothing is learned
    /// with no monitor or several, or while the accessory's own monitor was just unplugged and
    /// Poly is about to let it go.
    private func learn(_ info: AccessoryInfo) {
        if let owner = monitors.first(where: { $0.accessories.contains { $0.address == info.address } }) {
            if isAttached(owner) || missingSince[owner.id] != nil {
                rename(info)
                return
            }
        }
        guard attachedMonitors.count == 1, let attached = attachedMonitors.first else { return }

        let accessory = Accessory(address: info.address, name: info.name, kind: info.kind, productID: info.productID)
        var updated = monitors
        for index in updated.indices { updated[index].accessories.removeAll { $0.address == info.address } }
        updated.removeAll { $0.accessories.isEmpty && $0.id != attached.id }
        if let index = updated.firstIndex(where: { $0.id == attached.id }) {
            updated[index].name = attached.name
            updated[index].accessories.append(accessory)
            updated[index].accessories.sort { ($0.kind, $0.name) < ($1.kind, $1.name) }
        } else {
            updated.append(
                Monitor(
                    id: attached.id, name: attached.name, vendorID: attached.vendorID, productID: attached.productID,
                    accessories: [accessory]))
        }
        monitors = updated
        Log.switcher.info("learned \(info.name, privacy: .public) [\(info.address, privacy: .public)] for \(attached.name, privacy: .public) [\(attached.id, privacy: .public)]")
        if let monitor = monitors.first(where: { $0.id == attached.id }) { Notifier.learned(monitor) }
    }

    /// Keeps an accessory's name current when it is renamed in Bluetooth settings.
    private func rename(_ info: AccessoryInfo) {
        guard !info.name.isEmpty else { return }
        for monitorIndex in monitors.indices {
            for accessoryIndex in monitors[monitorIndex].accessories.indices
            where monitors[monitorIndex].accessories[accessoryIndex].address == info.address
                && monitors[monitorIndex].accessories[accessoryIndex].name != info.name
            {
                monitors[monitorIndex].accessories[accessoryIndex].name = info.name
            }
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(monitors) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// Bluetooth permission and power, from Core Bluetooth. Creating the manager asks for permission
/// the first time; IOBluetooth is used only once access is granted.
private final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    var onChange: (() -> Void)?
    private var manager: CBCentralManager?

    func start() {
        manager = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    var state: Switcher.BluetoothState {
        switch CBManager.authorization {
        case .denied, .restricted: return .denied
        case .notDetermined: return .waiting
        default: break
        }
        switch manager?.state {
        case .poweredOn: return .ready
        case .poweredOff: return .off
        case .unauthorized: return .denied
        default: return .waiting
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { onChange?() }
    }
}
