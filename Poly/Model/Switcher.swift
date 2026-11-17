import AppKit
import CoreBluetooth
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
final class Switcher {
    enum BluetoothState { case waiting, ready, off, denied }

    /// Called whenever anything the menu shows changes. Set by the app.
    var onChange: (() -> Void)?

    private(set) var monitors: [Monitor] = [] {
        didSet {
            save()
            onChange?()
        }
    }
    private(set) var attachedMonitors: [AttachedMonitor] = [] {
        didSet { onChange?() }
    }
    private(set) var bluetoothState: BluetoothState = .waiting {
        didSet { onChange?() }
    }
    /// Accessory addresses connected to this Mac, refreshed on every Bluetooth connection change.
    private(set) var connected: Set<String> = [] {
        didSet { onChange?() }
    }
    /// Accessories Poly has been trying to reach for a while.
    private(set) var needsNudge: Set<String> = [] {
        didSet { onChange?() }
    }
    /// The person's names for monitors, kept in Poly and iCloud since macOS cannot rename displays.
    let monitorNames = MonitorNames()
    /// Connected Apple accessories the one plugged-in monitor could have linked: not linked to it,
    /// and not about to be released by another monitor. The menu offers to link them.
    private(set) var linkable: [AccessoryInfo] = [] {
        didSet { onChange?() }
    }
    /// Accessories the person chose not to link, by monitor. Poly does not ask about them again.
    private(set) var declined: [String: Set<String>] = [:] {
        didSet {
            UserDefaults.standard.set(declined.mapValues { $0.sorted() }, forKey: Self.declinedKey)
            onChange?()
        }
    }
    /// Shows the Link alert and returns the addresses the person chose to link. Set by the app.
    var askToLink: ((LinkOffer) async -> Set<String>)?

    private let bluetooth = Bluetooth()
    private let access = BluetoothAccess()
    private let power = PowerEvents()
    private let wakefulness = Wakefulness()
    /// One running claim per plugged-in monitor. The token lets a cancelled claim that finishes late
    /// tell that a newer claim has replaced it.
    private var claims: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var releases: [String: Task<Void, Never>] = [:]
    /// When each unplugged monitor whose accessories this Mac still holds went missing.
    private var missingSince: [String: Date] = [:]
    /// Displays take a few seconds to come back after login or wake; nothing is released before this.
    private var holdReleasesUntil = Date.now.addingTimeInterval(15)
    /// Right after a wake the display list can still show the monitor from before the sleep; no
    /// claims until it has had a moment to catch up, or Poly could pair accessories another Mac uses.
    private var holdClaimsUntil = Date.distantPast
    /// The attached monitors are Poly's guess for a closed MacBook whose display macOS does not list
    /// yet (`inferredMonitors`), good enough to start connecting but not to link anything to.
    private var attachedAreInferred = false
    /// Accessories being renamed: Bluetooth reports the new name a moment later, and until then the
    /// menu shows the name asked for.
    private var renaming: Set<String> = []
    private var reconcileSoonPending = false
    private var sleeping = false
    /// Accessories already asked about while they stay connected; cleared when they disconnect.
    private var asked: Set<String> = []
    /// Accessories that just connected, gathered for a moment so ones connected together share one alert.
    private var gathering: (monitor: AttachedMonitor, accessories: [AccessoryInfo])?
    private var gatheringTask: Task<Void, Never>?
    private var offers: [(monitor: AttachedMonitor, accessories: [AccessoryInfo])] = []
    private var presentingOffer = false
    private var lastDisplayChange = Date.distantPast

    private static let storageKey = "monitors"
    private static let declinedKey = "declined"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode([Monitor].self, from: data)
        {
            monitors = saved
        }
        if let saved = UserDefaults.standard.dictionary(forKey: Self.declinedKey) as? [String: [String]] {
            declined = saved.mapValues(Set.init)
        }
    }

    func start() {
        monitorNames.onChange = { [weak self] in self?.onChange?() }
        Notifier.requestPermission()
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

    /// The person's name for a monitor, or the one macOS reports.
    func name(of monitor: Monitor) -> String { monitorNames[monitor.id] ?? monitor.name }

    /// A connected accessory shows its own name; one that is not shows the name it will be given.
    func name(of accessory: Accessory) -> String {
        connected.contains(accessory.address) ? accessory.name : accessory.pendingName ?? accessory.name
    }

    func rename(_ monitor: Monitor, to name: String) { monitorNames.set(name, for: monitor.id) }

    /// Renames the accessory itself: now if it is connected, otherwise the next time it connects.
    /// A rename the accessory does not take fails quietly; the menu shows whatever it reports.
    func rename(_ accessory: Accessory, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updateAccessory(accessory.address) { $0.pendingName = name == $0.name ? nil : name }
        if connected.contains(accessory.address) { applyPendingName(accessory.address) }
    }

    var needsAttention: Bool {
        bluetoothState == .denied || bluetoothState == .off || !needsNudge.isEmpty
    }

    /// Whether restarting Poly now (to install an update) would interrupt nothing: no pairing,
    /// connecting or releasing under way, no display change in the last 30 s, no sleep starting and
    /// no question waiting for an answer. A claim that is only waiting between retries is fine; the
    /// relaunched Poly picks it up.
    var isQuiet: Bool {
        !sleeping && releases.isEmpty && bluetooth.operations == 0 && !presentingOffer && gathering == nil
            && offers.isEmpty && Date.now.timeIntervalSince(lastDisplayChange) > 30
    }

    /// The monitor accessories can be linked to: the only one plugged in, as macOS lists it. Never a
    /// monitor Poly only guessed for a closed MacBook, and not right after a wake, while the list can
    /// still show the monitor from before the sleep: either would offer to link accessories to a
    /// monitor somewhere else (Learnings, 2026-11-17).
    var linkTarget: AttachedMonitor? {
        guard !attachedAreInferred, holdClaimsUntil <= .now, attachedMonitors.count == 1 else { return nil }
        return attachedMonitors.first
    }

    /// Stops managing an accessory, as if the person had answered Don't Link. It stays paired and
    /// connected; the menu offers to link it again while it is connected. A monitor left with no
    /// accessories is no longer listed.
    func unlink(_ accessory: Accessory) {
        var updated = monitors
        for index in updated.indices {
            if updated[index].accessories.contains(where: { $0.address == accessory.address }) {
                declined[updated[index].id, default: []].insert(accessory.address)
            }
            updated[index].accessories.removeAll { $0.address == accessory.address }
        }
        updated.removeAll { $0.accessories.isEmpty }
        monitors = updated
        needsNudge.remove(accessory.address)
        Notifier.clearNudge(for: accessory.address)
        reconcile()
    }

    func unlinkAll(_ monitor: Monitor) {
        for accessory in monitor.accessories { unlink(accessory) }
        missingSince[monitor.id] = nil
    }

    /// Links a connected accessory to the monitor plugged in now (the menu's Link item).
    func link(_ info: AccessoryInfo) {
        guard let monitor = linkTarget else { return }
        link(info, to: monitor)
        reconcile()
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
        lastDisplayChange = .now
        reconcile()
        // A monitor's registry details can land a moment after CoreGraphics reports it.
        reconcile(after: 2)
    }

    /// Checks right away and then every 2 s for half a minute: after a wake (including the
    /// background wake of a closed MacBook being plugged in) the monitor can take a while to show up.
    private func didWake() {
        Log.switcher.info(
            "woke; lid closed: \(Lid.isClosed), lid sleeps: \(Lid.closingSleeps)")
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
    /// only one monitor and the controller reports none yet, that one. With several known and none
    /// reported, or a different monitor reported, nothing is guessed: taking another monitor's
    /// accessories would take them from whoever is using them. A guess is only ever used to connect;
    /// nothing is linked to it (`linkTarget`).
    private func inferredMonitors() -> [AttachedMonitor] {
        var matches = Displays.registryMatches(monitors)
        if matches.isEmpty, monitors.count == 1, !Displays.registryReportsAny() { matches = monitors }
        Log.switcher.info(
            "closed on a monitor not listed yet; registry: \(Displays.registrySummary()), inferred: \(matches.map(\.name).joined(separator: ", "))"
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
            await pause(0.3)
            reconcileSoonPending = false
            reconcile()
        }
    }

    private func reconcile(after seconds: Double) {
        Task {
            await pause(seconds)
            reconcile()
        }
    }

    // MARK: Reconcile

    private func reconcile() {
        guard bluetoothState == .ready, !sleeping else { return }
        var attached = Displays.attached()
        let closedOnMonitor = isClosedOnMonitor
        // Only while macOS lists no real display yet: once it lists one, that list is the truth.
        let inferred = closedOnMonitor && attached.isEmpty
        if inferred { attached = inferredMonitors() }
        let newlyAttached = Set(attached.map(\.id)).subtracting(attachedMonitors.map(\.id))
        if attached != attachedMonitors || (inferred && !attached.isEmpty) != attachedAreInferred {
            let names = attached.map { "\($0.name) [\($0.id)]" }.joined(separator: ", ")
            Log.switcher.info("monitors attached: \(names.isEmpty ? "none" : names)\(inferred && !attached.isEmpty ? " (guessed)" : "")")
            attachedAreInferred = inferred && !attached.isEmpty
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
        offerLinks()

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
        guard monitor.accessories.contains(where: { bluetooth.isReleasable($0.address) }) else {
            missingSince[monitor.id] = nil
            return
        }
        let since = missingSince[monitor.id] ?? .now
        missingSince[monitor.id] = since
        // Closed and about to sleep for lack of a monitor: no time for a grace period.
        let sleepingSoon = Lid.isClosed && Lid.closingSleeps
        let releaseAt = sleepingSoon ? .now : max(since.addingTimeInterval(2), holdReleasesUntil)
        guard releaseAt <= .now else { return reconcile(after: releaseAt.timeIntervalSinceNow + 0.1) }
        Log.switcher.info("releasing accessories of \(monitor.name) [\(monitor.id)]")
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
            // Overlapped, keyboard first: each accessory starts once the previous one's pairing is
            // under way (its link is up, or 0.3 s after it started, or it ended; at most 3 s), so
            // the mouse pairs while the keyboard finishes instead of after it.
            var attempts: [(accessory: Accessory, task: Task<TakeResult, Never>)] = []
            var previous: Gate?
            for accessory in waiting {
                let after = previous
                let paged = Gate()
                previous = paged
                let task = Task {
                    await after?.wait(upTo: 3)
                    return await bluetooth.take(accessory.address, onPaged: { paged.open() })
                }
                attempts.append((accessory, task))
            }
            let tasks = attempts.map(\.task)
            await withTaskCancellationHandler {
                for (accessory, task) in attempts {
                    let result = await task.value
                    Log.switcher.info("take \(accessory.name): \(String(describing: result))")
                    refreshConnected()
                    if result == .connected {
                        needsNudge.remove(accessory.address)
                        Notifier.clearNudge(for: accessory.address)
                    } else if Date.now.timeIntervalSince(started) > 20, !needsNudge.contains(accessory.address) {
                        needsNudge.insert(accessory.address)
                        Notifier.couldNotConnect(name(of: accessory), address: accessory.address)
                    }
                }
            } onCancel: {
                for task in tasks { task.cancel() }
            }
            let elapsed = Date.now.timeIntervalSince(started)
            await pause(elapsed < 120 ? 1 : elapsed < 600 ? 5 : 20)
        }
    }

    private func release(_ monitorID: String) async {
        guard let monitor = monitors.first(where: { $0.id == monitorID }) else { return }
        for accessory in monitor.accessories where bluetooth.isReleasable(accessory.address) {
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
            if !lidClosed { await pause(1) }
            let listed = Set(Displays.attached().map(\.id))
            let attachedIDs: Set<String> = lidClosed ? [] : listed
            Log.switcher.info(
                "about to sleep; lid closed: \(lidClosed), lid sleeps: \(Lid.closingSleeps), listed: \(listed.sorted().joined(separator: ", "))"
            )
            for monitor in monitors where !attachedIDs.contains(monitor.id) {
                if Task.isCancelled { return }
                await releases[monitor.id]?.value
                await release(monitor.id)
            }
        }
        let deadline = Task {
            await pause(20)
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
        asked.formIntersection(now)
        let nudged = needsNudge.intersection(now)
        guard !nudged.isEmpty else { return }
        needsNudge.subtract(nudged)
        for monitor in monitors {
            for accessory in monitor.accessories where nudged.contains(accessory.address) {
                Notifier.clearNudge(for: accessory.address)
            }
        }
    }

    /// Keeps a connected accessory's saved details current. Nothing is linked here: an accessory
    /// connected while one monitor is plugged in is only offered (`offerLinks`).
    private func learn(_ info: AccessoryInfo) {
        let known = monitors.lazy.flatMap(\.accessories).first { $0.address == info.address }
        if known?.pendingName != nil { applyPendingName(info.address) }
        if known != nil { updateName(info) }
    }

    /// Finds accessories the plugged-in monitor could link and asks about the new ones. Accessories
    /// that connect within a second of each other share one alert; one that connects while an
    /// alert is open waits for its own.
    private func offerLinks() {
        guard let monitor = linkTarget else {
            if !linkable.isEmpty { linkable = [] }
            return
        }
        let candidates = bluetooth.connectedAccessories().filter { info in
            guard let owner = monitors.first(where: { $0.accessories.contains { $0.address == info.address } }) else {
                return true
            }
            return owner.id != monitor.id && missingSince[owner.id] == nil && !isAttached(owner)
        }
        if candidates.map(\.address) != linkable.map(\.address) { linkable = candidates }

        let new = candidates.filter {
            !asked.contains($0.address) && !(declined[monitor.id]?.contains($0.address) ?? false)
        }
        guard !new.isEmpty else { return }
        asked.formUnion(new.map(\.address))
        if gathering?.monitor.id != monitor.id { gathering = (monitor, []) }
        gathering?.accessories.append(contentsOf: new)
        gatheringTask?.cancel()
        gatheringTask = Task {
            await pause(1)
            guard !Task.isCancelled, let batch = gathering else { return }
            gathering = nil
            offers.append(batch)
            await presentOffers()
        }
    }

    private func presentOffers() async {
        guard !presentingOffer, let askToLink else { return }
        presentingOffer = true
        defer { presentingOffer = false }
        while !offers.isEmpty {
            let (monitor, accessories) = offers.removeFirst()
            // Something may have changed while it waited: unplugged, disconnected, linked from the menu.
            let still = accessories.filter { info in linkable.contains { $0.address == info.address } }
            guard !still.isEmpty else { continue }
            guard linkTarget?.id == monitor.id else {
                reask(still)
                continue
            }
            let offer = LinkOffer(
                monitorName: monitorNames[monitor.id] ?? monitor.name,
                accessories: still.map { Accessory($0, name: name(of: $0)) })
            Log.switcher.info(
                "asking to link \(still.map(\.name).joined(separator: ", ")) to \(offer.monitorName) [\(monitor.id)]")
            let chosen = await askToLink(offer)
            // The display can change while the question is open; the answer was about the one it named.
            guard linkTarget?.id == monitor.id else {
                Log.switcher.info("\(offer.monitorName) is no longer connected; not using the answer")
                reask(still)
                continue
            }
            for info in still {
                if chosen.contains(info.address) {
                    link(info, to: monitor)
                } else {
                    declined[monitor.id, default: []].insert(info.address)
                    Log.switcher.info("not linking \(info.name) [\(info.address)]")
                }
            }
            reconcile()
        }
    }

    /// Lets accessories gathered for a display that is gone be asked about again, for whichever
    /// display is connected once things settle.
    private func reask(_ accessories: [AccessoryInfo]) {
        asked.subtract(accessories.map(\.address))
        reconcile(after: 0.5)
    }

    /// The name to show for an accessory that may not be linked yet.
    private func name(of info: AccessoryInfo) -> String {
        monitors.lazy.flatMap(\.accessories).first { $0.address == info.address }.map(name(of:)) ?? info.name
    }

    /// Records that an accessory belongs to a monitor, moving it from any other.
    private func link(_ info: AccessoryInfo, to attached: AttachedMonitor) {
        let known = monitors.lazy.flatMap(\.accessories).first { $0.address == info.address }
        declined[attached.id]?.remove(info.address)
        let accessory = Accessory(
            address: info.address, name: info.name, pendingName: known?.pendingName, kind: info.kind,
            productID: info.productID)
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
        Log.switcher.info("linked \(info.name) [\(info.address)] to \(attached.name) [\(attached.id)]")
    }

    /// Keeps an accessory's name current when it is renamed in Bluetooth settings.
    private func updateName(_ info: AccessoryInfo) {
        guard !info.name.isEmpty, !renaming.contains(info.address) else { return }
        updateAccessory(info.address) { $0.name = info.name }
    }

    /// Gives a connected accessory the name the person chose for it. Tried once: the pending name
    /// is cleared first, and the accessory's own name is what shows afterwards either way.
    private func applyPendingName(_ address: String) {
        guard let name = monitors.lazy.flatMap(\.accessories).first(where: { $0.address == address })?.pendingName
        else { return }
        // Shown at once; Bluetooth reports the new name a moment later (Learnings, 2026-11-17).
        renaming.insert(address)
        updateAccessory(address) {
            $0.pendingName = nil
            $0.name = name
        }
        Task {
            let reported = await bluetooth.rename(address, to: name)
            renaming.remove(address)
            guard let reported, !reported.isEmpty else { return }
            updateAccessory(address) { $0.name = reported }
        }
    }

    /// Changes an accessory wherever it is saved, saving only when something changed.
    private func updateAccessory(_ address: String, _ change: (inout Accessory) -> Void) {
        var updated = monitors
        for monitorIndex in updated.indices {
            for accessoryIndex in updated[monitorIndex].accessories.indices
            where updated[monitorIndex].accessories[accessoryIndex].address == address {
                change(&updated[monitorIndex].accessories[accessoryIndex])
            }
        }
        if updated != monitors { monitors = updated }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(monitors) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

/// A question for the person: link these accessories to this monitor?
struct LinkOffer {
    let monitorName: String
    let accessories: [Accessory]
}

extension Accessory {
    init(_ info: AccessoryInfo, name: String) {
        self.init(address: info.address, name: name, kind: info.kind, productID: info.productID)
    }
}

/// Opens once; waiters resume then, or after their timeout.
private final class Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        guard !isOpen else { return }
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    func wait(upTo seconds: Double) async {
        guard !isOpen else { return }
        Task {
            await pause(seconds)
            open()
        }
        await withCheckedContinuation { waiters.append($0) }
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
