# Learnings

What building and testing Poly taught us, newest first. Add to it whenever something surprises
you: the symptom, the cause, how it was confirmed, and what the code does about it.

## 2026-11-15: the closed MacBook still did not release

**Evidence.** The unplugged MacBook's log: `about to sleep; attached: 610-ae3a-1439526375` at
15:20:02 (one second after unplugging, the display list still showed the Studio Display, and the
lid check did not fire, so `AppleClamshellCausesSleep` was not yet true either); then `woke` at
15:20:50 when the lid was opened, `monitors attached: none`, and the release 15 s later (the
post-wake hold).

**Lesson.** At sleep time there is no trustworthy "monitor is gone" signal. Do not ask for one;
make sleep itself the signal.

**Fix.** While a closed MacBook has a known monitor plugged in, Poly holds
`PreventUserIdleSystemSleep` (display sleep still allowed; lid and unplug sleep are not affected),
so a closed MacBook only sleeps when unplugged or put to sleep on purpose, and Poly releases
everything whenever a closed MacBook sleeps. The log line now records lid state, lid-sleeps and
the listed monitors.

**Also.** For the incoming closed MacBook: check on every wake right away and every 2 s for 30 s,
and declare user activity when a known monitor is newly plugged in with the lid closed, so the
display wakes and the keyboard can type the password. Pre-login after a restart is out of reach
for a session app.

## 2026-11-15: menu subtitles and grayed titles from SwiftUI

How SwiftUI menu labels bridge to `NSMenuItem` (macOS 27, checked by reading the bridged items):

- `Label { Text } icon: { Image }` followed by a second `Text` gives title, icon and **subtitle**
  (`NSMenuItem.subtitle`). Two Texts inside the Label's title, or in a VStack, give no subtitle;
  two plain Texts give a subtitle but the image then loses `.titleAndIcon` visibility.
- `.foregroundStyle(.secondary)` on the title Text becomes an `attributedTitle` with a gray color:
  grayed out but still enabled, so submenus stay reachable. `.disabled(true)` on a `Menu` left
  the item enabled.
- `NSMenuItem.subtitle` needs macOS 14.4; on 14.0 to 14.3 the subtitle is simply absent.

## 2026-11-15: handoffs work; clamshell unplug did not release

**Result.** After the synchronous-call fix, a lid-open handoff worked: the taking Mac's log shows
each accessory "not bonded, answer check: 0x00000000", "pairing finished: 0x00000000" and
connected, in about two seconds each.

**Symptom.** Unplugging a MacBook in clamshell mode left both accessories paired to it while it
slept; the other Mac could not take them until the lid was opened, when the 15 s post-wake hold
expired and the woken Mac released them.

**Likely cause.** The sleep handler decided which monitors were gone from the CoreGraphics display
list, which can still list the monitor that was just unplugged while the Mac starts to sleep
(confirmed by the next test's log, below).

**First fix (not enough).** With the lid closed, Poly asked the power manager instead:
`AppleClamshellState` and `AppleClamshellCausesSleep` both true meaning no external display.
`AppleClamshellCausesSleep` had not changed yet either; see the entry above. The same check releases immediately (no 2 s grace) when a
monitor disappears with the lid closed. Look for "about to sleep with the lid closed and no
monitor" in the log to confirm on hardware.

## 2026-11-15: handoffs stuck at "Needs a Nudge"

**Symptom.** First test on two MacBooks: after unplugging one and plugging in the other, both
accessories stayed at "Needs a Nudge" until they were paired by cable.

**Cause.** Before pairing an accessory it does not hold, Poly checks the accessory answers with a
remote name request. Poly used the asynchronous form with a target and implemented
`remoteNameRequestComplete:status:`, but `-remoteNameRequest:withPageTimeout:` calls back
`remoteNameRequestComplete:status:name:` (three parts; the shorter `-remoteNameRequest:` uses the
two-part one). IOBluetooth targets are informal protocols, so nothing warned: the callback never
arrived, every check timed out after 10 s, and Poly never reached pairing. Found by reading the
discussion in `IOBluetoothDevice.h`.

**Fix.** Connecting, the answer check and forgetting now use the synchronous calls (`nil` target),
the same as blueutil and Magic Switch, on one serial queue so the main thread never waits.
`IOBluetoothDevicePair` stays on the main run loop because its delegate needs it. Every step now
logs to the unified log (`Log.swift` has the command).

**Also fixed.** An accessory connected by hand kept its "Needs a Nudge" mark (and the warning icon)
because only Poly's own successful connections cleared it. Refreshing connections now clears it
however the accessory connected.

**Not yet confirmed on hardware:** whether the releasing Mac's forget worked in that test. The new
logs answer it next time ("releasing accessories of…", "forgotten, still paired: false").

## 2026-11-15: building the first version

- **macOS 26 hides menu item images by default.** `NSMenuItem.preferredImageVisibility` is
  automatic (0) for SwiftUI menu items, and the menu drew no icons although every item had an
  image. `.labelStyle(.titleAndIcon)` sets it to visible (1). Confirmed by reading the property on
  the bridged `SwiftUIMenuItem`s in a scratch app.
- **Inspecting a `MenuBarExtra` menu without screenshots:** the status bar window answers
  `value(forKey: "statusItem")`; call `menu.delegate?.menuNeedsUpdate?(menu)` to populate the
  SwiftUI menu, then read its items. Screen captures from an agent trigger a screen recording
  prompt; avoid them.
- **Run the app through LaunchServices** (`open`), never its executable from a shell: the shell is
  then responsible for the Bluetooth permission and TCC kills the process for lacking a usage
  description.
- **System device artwork is all on disk.** Monitors: the `Icons.plist` override table in
  `/System/Library/Displays/Contents/Resources/Overrides` maps vendor and product IDs to device
  types (`com.apple.studio-display`) or images. Magic Mouse has a Bluetooth vendor/product UTType;
  keyboards and trackpads do not, but BezelServices plug-ins ship `Keyboard2.icns` (Magic
  Keyboard), `Keyboard3.icns` (Touch ID), `ExtendedKeyboard2.icns` (numeric keypad),
  `Mouse.icns` and `MagicTrackpad.icns`.
- **Proven handoff sequence** (from Magic Switch, blueutil and MonkeySwitcher): the giving Mac
  only calls the private `remove`, which tells an Apple accessory it is unpaired so it returns to
  pairing mode; the taking Mac connects if bonded, else checks the accessory answers, forgets a
  stale bond and waits 0.5 s, pairs (no built-in timeout; first handoffs can take 30 to 45 s),
  then connects. Pairing an accessory another Mac still holds hangs. An accessory unpaired for a
  long time stops listening until clicked or power-cycled.
- **Opening a connection to a stale bond without authentication** can connect for a moment and
  drop, which would loop forever without re-pairing; Poly requires authentication.
- **Icon Composer `.icon` files build fine with SVG layers** written by hand (`icon.json` with
  `fill`, `groups` of `layers`, `supported-platforms`); actool emits both `Assets.car` and a legacy
  `AppIcon.icns` for macOS 14.
