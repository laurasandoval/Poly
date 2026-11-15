# Learnings

What building and testing Poly taught us, newest first. Add to it whenever something surprises
you: the symptom, the cause, how it was confirmed, and what the code does about it.

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
