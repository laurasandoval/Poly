# Poly spec

Poly makes a monitor's Apple keyboard, mouse and trackpad follow whichever Mac is plugged into
that monitor. Plug in: they connect. Unplug: they are let go, ready for the next Mac. This is the
design to implement; change it deliberately, not as a side effect.

## The problem

A household (and an office) shares monitors between several MacBooks. Each monitor has its own
Magic Keyboard and Magic Mouse or Trackpad. Apple accessories pair with one Mac at a time, so
switching Macs today means plugging each accessory into the new Mac with a cable, pressing keys or
clicking until it pairs, unplugging it, and repeating for the next one.

## The model

**The monitor cable is the switch.** Only one Mac can be plugged into a monitor at a time, so the
cable already says who should own that monitor's accessories. Each Mac reacts only to its own plug
and unplug events; Macs never talk to each other and need no shared account, network or server.

- One set of accessories belongs to each monitor. A Mac plugged into a monitor holds that
  monitor's set; any number of monitors (office, kitchen, work) work the same way.
- **Releasing means forgetting (unpairing), not just disconnecting.** A merely disconnected
  accessory still has this Mac as its host and keeps trying to reconnect to it, which blocks the
  next Mac. Told it is unpaired, an Apple accessory returns to pairing mode by itself.
- **Taking means connecting, pairing first when needed.** If this Mac still holds a bond (it was
  asleep at the desk), connecting is enough. Otherwise Poly checks the accessory answers, then
  pairs and connects it. A stale bond (another Mac paired the accessory since) is replaced the
  same way.

## Triggers

Every trigger runs one idempotent `reconcile()`: compare the monitors plugged in now with what
this Mac holds, and act on the difference. A missed event is repaired by the next one.

| Trigger | Source |
|---|---|
| Monitor plugged in or unplugged | `NSApplication.didChangeScreenParametersNotification`, re-checked 2 s later |
| Accessory connected or disconnected | IOBluetooth connect and disconnect notifications |
| About to sleep | `IORegisterForSystemPower`, `kIOMessageSystemWillSleep` |
| Woke up | `kIOMessageSystemHasPoweredOn` (and `SystemWillNotSleep`) |
| Bluetooth permission or power changed | Core Bluetooth `centralManagerDidUpdateState` |

### Plugged in: claim

For each accessory of the attached monitor that is not connected, keyboard first, then mouse,
then trackpad, overlapped: each starts once the previous one's pairing is under way
(`devicePairingConnected:`, 0.3 s after its pairing started, or it ended; at most 3 s), so the mouse
pairs while the keyboard finishes. A controller pages one device at a time, so they never start at the same instant.

1. Bonded on this Mac → open a connection (5 s page timeout). Connected → done.
2. Otherwise, check the accessory answers (remote name request, 2.5 s page timeout). No answer →
   it is asleep, off, away or held by another Mac; try again later. Do not forget a bond for an
   accessory that does not answer.
3. Answers but the bond is stale → forget it and wait 0.5 s (re-pairing inside the unbond window
   fails).
4. Pair with `IOBluetoothDevicePair`: confirm numeric comparison, answer legacy PIN requests with
   0000, and show keyboard passkeys in a notification. Pairing has no timeout of its own; stop it
   after 60 s, or as soon as the monitor is unplugged. Connect once pairing finishes.

Retry every second or so for two minutes, so clicking a sleeping mouse connects it within a few
seconds; every 5 s up to ten minutes; every 20 s after that. After 20 s without an answer the
accessory **needs a nudge**: the menu says so and one notification asks the person to click it,
press a key, or switch it off and on.

### Unplugged: release

When a monitor whose accessories this Mac holds goes missing, wait 2 s (a loose cable or a
display reconfiguration must not hand accessories away), then forget each of them. Forgetting is
synchronous IPC to bluetoothd that can take seconds, so it runs on a serial background queue.

After login and after wake, nothing is released for 15 s: displays can take several seconds to
come back, and releasing then would only churn.

### About to sleep: release before allowing sleep

A closed MacBook unplugged from its monitor sleeps immediately, so there is no time for the normal
release. macOS waits (up to about 30 s) for every app registered with `IORegisterForSystemPower`
to allow sleep; Poly releases, then allows sleep, giving up after 20 s.

At that moment neither the display list nor the power manager can say the monitor is gone: on
the first clamshell test the display list still showed the monitor a second after unplugging, and
`AppleClamshellCausesSleep` had not changed either ([Learnings](Learnings.md)). So the rule does
not depend on them:

- **While a closed MacBook has a known monitor plugged in, Poly keeps it from idle-sleeping**
  (`PreventUserIdleSystemSleep`; the display still sleeps). That assertion does not stop lid or
  unplug sleep.
- **So a closed MacBook that sleeps was unplugged**, or put to sleep on purpose: Poly releases the
  accessories of every monitor. `AppleClamshellState` on `IOPMrootDomain` says whether the lid is
  closed.
- With the lid open, Poly waits 1 s for the display list to settle and releases the monitors no
  longer listed; an idle sleep at the desk keeps the monitor, so the keyboard can still wake it.

Choosing Sleep from the Apple menu on a closed MacBook at the desk releases the accessories too;
opening the lid (or plugging in again) brings them back.

### Plugged into a closed MacBook: wake it

Plugging a closed MacBook into a monitor wakes it for only about a second, in the background: the
display stays off, the display list shows only macOS's stand-in display (vendor 'unkn', product
'virt', which Poly ignores), and the Mac goes back to sleep. The power manager does know a monitor
is there: `AppleClamshellCausesSleep` is false. So on every wake, a closed MacBook with
`AppleClamshellCausesSleep` false, on a Mac that has learned a monitor, declares user activity
(`IOPMAssertionDeclareUserActivity`), which wakes it fully like a key press. The display lights,
the display list catches up, and the accessories connect so the lock screen can be unlocked with
them. The same condition cancels an idle sleep (`kIOMessageCanSystemSleep`).

After any wake, Poly checks right away and every 2 s for 30 s, but starts no claim for 1.5 s:
the display list can still show the monitor from before the sleep, and claiming on that would pair
accessories another Mac is using.

Poly runs in the person's session, so it works at the lock screen but not at the login window
after a restart (FileVault or a logged-out Mac); that would need a privileged daemon.

If the release is missed anyway (Poly was not running), the next Mac's retries keep paging. A Mac
that still holds the bond wakes when the accessory pages it, sees its monitor is gone and releases
it then.

## Learning

There is no setup. An Apple keyboard, mouse or trackpad that is connected while exactly one
external monitor is plugged in belongs to that monitor from then on. The first time on each Mac,
the person connects the accessories the old way (a cable, or Bluetooth settings), or installs Poly
while they are already connected, and Poly takes over from there.

- Apple accessories only: peripheral class (keyboard, pointing device or combo) and Apple's vendor
  ID from the Device ID record (Bluetooth SIG 0x004C or USB 0x05AC), or "Magic" in the name when
  the record is missing. AirPods, other brands and multi-host keyboards are never touched.
- Mouse or trackpad comes from the product ID or the name.
- An accessory belongs to one monitor. Connecting it while another monitor is plugged in moves it
  there, except while its own monitor was just unplugged and its release is pending.
- With several external monitors at once (a Sidecar iPad, AirPlay), nothing new is learned; known
  monitors still work.
- Learning updates names when accessories are renamed.
- Each Mac learns on its own. The list lives in that Mac's UserDefaults (`monitors`, JSON).

## Identifying monitors

`vendor-product-serial`, from CoreGraphics' vendor and model numbers plus a serial: the
registry's alphanumeric serial on Apple silicon (`DisplayAttributes` → `ProductAttributes` on
`IOMobileFramebuffer` services), else the EDID serial from `CGDisplaySerialNumber`, else 0. The
serial is what tells two Studio Displays apart. Built-in screens never count; mirrored outputs
count once. Virtual displays (Sidecar, AirPlay, dummy-display apps) count like any monitor: telling
them apart would rest on registry details too easy to get wrong, and a wrong guess would hide a
real monitor.

## Interface

A menu bar icon (∞, a nod to the name) and a standard menu. Nothing else, no windows, no settings.

- One item per monitor, with its system icon (System Settings' own artwork: the Displays override
  table, then Finder's device types) and a subtitle: "Connected • 2 accessories" while plugged in
  ("Connecting…" or "Needs a Nudge" in place of "Connected" when that applies), "Not Connected"
  otherwise. Monitors with the same name are numbered
  ("Studio Display 2").
- Inside each monitor, its accessories with the system's artwork for Magic Keyboard (Touch ID and
  numeric keypad variants by name), Magic Mouse and Magic Trackpad (the images macOS shows in its
  connection notices). Nothing is bundled; a missing image falls back to an SF Symbol. While the
  monitor is plugged in, the subtitle says "Connected", "Connecting…", or what to do when it needs
  a nudge; otherwise it says "Not Connected". Each accessory's submenu
  offers **Rename…** and **Forget Accessory**, which also unpairs it from this Mac like Bluetooth
  settings' Forget (otherwise it would be relearned the moment it reconnects). Each monitor's
  submenu offers **Rename…**, and an unplugged monitor can be forgotten from it ("Forget Office").
- **Renaming** uses a standard alert with one text field. An accessory is renamed itself, like
  Bluetooth settings' Name field (IOBluetoothDevice's private `rename:`): at once when connected,
  otherwise the name waits (`pendingName`, shown in the menu meanwhile) and is given once, the
  next time it connects. A connected accessory always shows the name Bluetooth reports, so a
  rename that does not take simply does not show. macOS cannot rename a display, so a monitor's
  name lives in Poly (`monitorNames` in UserDefaults), mirrored to iCloud key-value storage under
  `monitor-name.<monitor id>` so the person's other Macs share it; without iCloud it stays on this
  Mac. Each person's Macs keep their own names for a shared monitor. An empty name goes back to
  the one macOS reports.
- The icon turns into a warning when Bluetooth is off or denied, or an accessory needs a nudge.
- **Open at Login** is turned on at the first launch from an Applications folder, since Poly only
  works while running, and stays however the person sets it after that. Runs from Xcode's build
  folder never register a login item.
- Menu rows use `.labelStyle(.titleAndIcon)`: from macOS 26, menu item images are hidden unless
  their visibility preference says otherwise.

Notifications (permission asked the first time Poly learns a monitor, when the person has a
working keyboard and mouse): what Poly learned, a nudge for an accessory that does not answer, and
a passkey to type when a keyboard asks for one.

## Platform

- macOS 14 or later, Apple silicon or Intel. SwiftUI `MenuBarExtra`, Observation, Swift 6 with
  main-actor default isolation. IOBluetooth for pairing (Core Bluetooth cannot pair classic HID
  accessories), Core Bluetooth only for the permission and power state.
- Forgetting uses IOBluetoothDevice's private `remove` selector, the same as blueutil and Magic
  Switch. Poly is not sandboxed and is not for the Mac App Store; it is signed with the team's
  Apple Development certificate and runs with the hardened runtime.
- `NSBluetoothAlwaysUsageDescription` and `LSUIElement` are in the generated Info.plist.
- Monitor names sync through the `com.apple.developer.ubiquity-kvstore-identifier` entitlement
  (`$(TeamIdentifierPrefix)$(CFBundleIdentifier)`, in `Poly.entitlements`), which embeds a Mac
  App Development provisioning profile.
- A process activity (`userInitiatedAllowingIdleSystemSleep`) keeps App Nap from stretching the
  short timers; Poly has no timers while idle and never prevents sleep.

## Known limits

- An accessory left unpaired for a long time stops listening and needs a click, a key press, or
  switching off and on. The nudge covers this.
- macOS may show its own "Connection Request" alert after a switch (seen once, for the mouse, since
  pairings overlap); Poly cannot suppress it, and the accessory works without answering it.
- A Mac without Poly does not release accessories; unplug and let a Poly Mac take over, or forget
  them in that Mac's Bluetooth settings.
- Two identical monitors whose serials macOS cannot read are indistinguishable.
- An accessory connected while a Sidecar iPad or AirPlay screen is the only external display is
  learned for it. Forget it from the menu if that was not meant.

## Diagnosing

Every handoff step goes to the unified log (subsystem `work.lau.poly`): monitors attached, each
take result with IOReturn codes, pairing, releases with whether the accessory is still paired, and
sleep. See `Poly/System/Log.swift` for the command. Findings go in
[Learnings](Learnings.md).

## Manual test plan

On two Macs with Poly and one monitor with a Magic Keyboard and Magic Mouse:

1. First run on Mac A with the accessories connected: Poly asks for Bluetooth, learns the monitor
   and posts "Poly knows Studio Display".
2. Unplug A with the lid open: within a few seconds both accessories disconnect and disappear from
   A's Bluetooth settings.
3. Plug in Mac B and connect the accessories once by cable: B learns them.
4. Unplug B, plug A back in: A connects both without a cable. Clicking the mouse speeds it up.
5. With A closed in clamshell, unplug: A sleeps; plug in B: B connects both.
6. Leave A plugged in and let it idle-sleep: the keyboard still wakes it.
7. Switch the mouse off while plugged in: after about 20 s the menu and a notification ask for a
   nudge; switching it on connects it.
