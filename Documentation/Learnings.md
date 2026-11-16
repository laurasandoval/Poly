# Learnings

What building and testing Poly taught us, newest first. Add to it whenever something surprises
you: the symptom, the cause, how it was confirmed, and what the code does about it.

## 2026-11-15: a crash on a Bluetooth connection notification

**Symptom.** A crash report (`EXC_BREAKPOINT`, `_dispatch_assert_queue_fail` under
`swift_task_isCurrentExecutor`) from the development build: an IOBluetooth connection notification
(`-[IOBluetoothConcreteUserNotification objcNotificationRoutine:]`, posted from
`-[IOBluetoothCoreBluetoothCoordinator centralManager:connectionEventDidOccur:forPeripheral:]`)
arrived on `com.apple.bluetooth.iobluetooth.coordinatorQueue`, not the main thread, and Swift 6's
main-actor check stopped Poly. 0.1 has the same code.

**Lesson.** IOBluetooth callbacks are not guaranteed to arrive on the main run loop on current
macOS, whatever the older documentation implies. **Fix.** The notification and pairing delegate
callbacks are `nonisolated` and hop to the main actor (`onMainActor` in `Bluetooth.swift`).

## 2026-11-15: macOS 12 support

The owner's girlfriend's Mac runs macOS 12.7.6. What stood in the way, from a build at a macOS
12 deployment target: SwiftUI's `MenuBarExtra` (13), Observation (14), `SMAppService` (13),
`Task.sleep(for:)` and `Duration` (13), `NSApp.activate()` (14), `URL(filePath:)` (13). The menu
is now AppKit, state changes reach it through one `onChange` callback, and Open at Login on 12 is
a LaunchAgent (no API lets an app add itself there without a helper app). `NSMenuItem.subtitle`
needs 14.4, so older systems get a two-line attributed title. Built and notarized on macOS 27;
**not yet run on macOS 12** itself.

## 2026-11-15: silent updates

**Tested locally:** a 9.0.0 build (development signing, throwaway Ed25519 key, feed on
127.0.0.1) launched, found 9.0.1, downloaded it, and installed and relaunched as 9.0.1 within the
same second (`downloaded 9.0.1; installing when quiet`, `installing update and relaunching`), with
no window. **Released 0.1** (build 44): the Developer ID export embeds a profile with the iCloud
key-value entitlement, notarization was accepted for the app and the DMG, Gatekeeper accepts both,
and `releases/latest/download/appcast.xml` and `Poly.dmg` download anonymously. Still to see on a
real Mac: names syncing in a Developer ID build. **Updated 0.1 to 0.2 for real** on the owner's
Mac: with `SULastCheckTime` set back, 0.1 fetched the feed from GitHub, downloaded 0.2, installed
and relaunched in under a second, with nothing on screen.

**Lessons.**
- Sparkle 2's `updater(_:willInstallUpdateOnQuit:immediateInstallationBlock:)` returning YES is
  the supported way for a background app to install without UI; returning NO lets Sparkle show
  the update after `SUScheduledImpatientCheckInterval` instead. Gentle reminders
  (`standardUserDriverShouldHandleShowingScheduledUpdate` returning NO) keep an update that needs
  an administrator from popping up.
- `SUEnableAutomaticChecks` in Info.plist skips Sparkle's "check automatically?" question.
- A plain `http://127.0.0.1` feed works for testing; Sparkle only logs an HTTPS warning.
- In zsh, `log` is a builtin: use `/usr/bin/log show`.
- Apple's capability table lists iCloud key-value storage for Developer ID, so monitor names should
  keep syncing in releases; confirm on the first one.

## 2026-11-15: asking before linking

- **macOS has no notification style an app can choose.** Banners vs. persistent alerts is the
  person's setting in System Settings; `UNNotificationSettings.alertStyle` only reads it. MediaLab's
  on-top pairing prompt is its own floating window, not a notification. Poly asks with `NSAlert`
  instead (no window of its own), which stays until answered.
- **The passkey notification went away** untested: Magic accessories were never seen to ask for
  one, and the delegate callback is now only logged ("pairing asked to type a passkey"). If that
  line ever appears with no prompt on screen, the keyboard could not finish pairing.

## 2026-11-15: renaming

- **A styled menu title drops the subtitle.** With `.foregroundStyle(.secondary)` on the title
  `Text` (to gray unplugged monitors), the menu item showed no subtitle at all. Titles are plain
  now; "Not Connected" says it instead.
- **Menu shortcuts do not follow the open submenu.** With ⌘R on every Rename… item, ⌘R always
  renamed the first accessory of the first monitor: an open menu matches key equivalents across
  its whole tree, in item order, not just in the submenu showing. Removed; making it follow the
  open submenu would need AppKit menu delegates.
- **Displays cannot be renamed in macOS.** No setting or API; only third-party display override
  files (BetterDisplay) change the system name. Poly keeps monitor names itself and syncs them with
  `NSUbiquitousKeyValueStore`.
- **Accessories:** `IOBluetoothDevice.name` is read-only in the headers, but the runtime (macOS 27)
  has private `rename:`, `setDisplayName:` and `setName:`. Poly calls `rename:` on the Bluetooth
  queue and logs the name the device reports afterwards ("renamed to …, reports …"). **Not yet
  confirmed on hardware** whether the name reaches the accessory itself (another Mac seeing it) or
  stays in this Mac's Bluetooth records.
- **The iCloud key-value entitlement could not be added:** with it, automatic signing failed with
  "PLA Update available … agree to the latest Program License Agreement" and then "No profiles for
  'work.lau.poly'". After the owner accepted the agreement, automatic signing created the profile
  and the build embeds it. `NSUbiquitousKeyValueStore` also works locally without the entitlement.
  The install script's fallback (ad hoc signing) cannot carry this entitlement, so on a Mac
  without the team's certificate that build would fail to launch; drop the entitlement there.

## 2026-11-15: a "Connection Request" dialog after overlapping

**Observed once**, on the first handoff with the 0.3 s overlap: macOS showed its Bluetooth
"Connection Request" dialog for the Magic Mouse. The mouse worked without answering it. Never
seen with sequential pairing. Magic Switch users report the same dialog (its issues #109, #150);
its author says apps cannot suppress it.

**Suspected cause (unconfirmed):** pairing the mouse while the keyboard is still pairing lets the
mouse try to connect to the Mac on its own before Poly's pairing finishes, which macOS treats as
an unexpected request. No log was captured.

**If it recurs:** capture the log (the pairing steps are logged) and compare the mouse's answer
check and `pairing started/connecting/connected` lines with the keyboard's. Options: start the
mouse later (after `pairing finished` of the keyboard minus a margin) or return to sequential
pairing, which costs 2 to 3 s.

## 2026-11-15: early claim works; the overlap did not happen

**Evidence** (MacBook Air taking over, closed): `woke` at 16:20:56.267 and, in the same
millisecond, `closed on a monitor not listed yet; registry: none, inferred: Studio Display`.
Keyboard paired at +2.0 s, mouse at +5.1 s (was 12.4 s). But the mouse's answer check came 10 ms
after the keyboard finished: `devicePairingConnected:` never fired, presumably because the answer
check had just brought the link up, and the 3 s fallback was longer than the keyboard's pairing.

**Lessons.**
- `DisplayAttributes` is not published during the background wake of a closed MacBook being
  plugged in (`registry: none`), so the early claim only works on a Mac that knows one monitor.
- Do not rely on `devicePairingConnected:`; every pairing callback is now logged to see which ones
  macOS actually sends.

**Change.** The next accessory now also starts 0.3 s after the previous pairing starts. Expected:
the mouse finishes about 3 s after wake instead of 5.

## 2026-11-15: v1.0 works end to end; speed and size

**Confirmed on hardware** (MacBook Air and MacBook Pro, closed, sharing one Studio Display): unplug
releases before sleep, plugging in wakes the closed Mac, and the accessories connect. Tagged
`v1.0`.

**Where the time goes** (MacBook Pro log, plugged in closed at 15:43:14.53):

| Step | Elapsed |
|---|---|
| Wake, `waking the display` | 0 s |
| Display list shows the Studio Display, claim starts | 1.6 s |
| Keyboard answer check (about 10 ms), pairing finished | 5.6 s |
| Mouse pairing finished (it waits for the keyboard) | 12.4 s |

Pairing takes 2 to 4 s for the keyboard and 3 to 8 s for the mouse. The first change: when a
closed MacBook wakes with the power manager reporting a monitor and macOS lists no real display
yet, Poly claims right away for the known monitor the display controller reports, or the only
monitor it knows, which skips the 1.6 s wait.

**Overlapping pairings.** Research (headers, a runtime dump of IOBluetooth on macOS 27, community
reports) found no documentation or reports either way on concurrent `IOBluetoothDevicePair`s; the
Core spec allows several ACL links, each authenticated on its own handle, but a controller pages
one device at a time. Poly now starts the next accessory when the previous one reports
`devicePairingConnected:` (paging done), at most 3 s later. Confirm on hardware: the mouse's
"pairing finished" should land within a couple of seconds of the keyboard's, not after it.

**Dead ends.** Magic accessories (second generation on) keep one host's link key, so the Mac
taking over must pair again; importing link keys between Macs needs root, keychain items scoped to
bluetoothd, and still fails because the key is bound to the other Mac's Bluetooth address.
Released accessories stay in pairing mode for about 3 minutes (Apple's generic figure), so a click
is needed only after longer gaps.

**Size.** The Release app was 3.0 MB: the asset catalog 1.7 MB (1.46 MB of it two flattened 1024 px
renders of the Icon Composer icon; the Liquid Glass layers are about 3 KB) and a universal,
unstripped 1.2 MB binary. `DEPLOYMENT_POSTPROCESSING = YES` (strip), `-Osize`, and building only
the installing Mac's architecture bring the binary to 350 KB and the app to 2.1 MB. A macOS 26
deployment target does not drop the flattened icon renders (measured), so it would buy nothing.

## 2026-11-15: releasing works; a closed MacBook being plugged in did not wake

**Evidence** (logs from both MacBooks). Every unplug now logs `about to sleep; lid closed: true`
and both accessories `forgotten, still paired: false`, and the other Mac pairs them in about 2 s
each once it is awake. But plugging a closed MacBook in produced only a one-second wake:
`woke; lid closed: true`, `monitors attached:  [756e6b6e-76697274-0]` (macOS's stand-in display,
'unkn' 'virt'), then `about to sleep; lid closed: true, lid sleeps: false` a second later. The
display never lit, so the person had to open the lid.

**Lessons.**
- The brief wake of a closed MacBook being plugged in does not list the real monitor, but
  `AppleClamshellCausesSleep` is already false: the power manager knows a display is attached.
  (At unplug time the same flag lags; it is only trustworthy in this direction.)
- The stand-in display ('unkn' 'virt') appears in `CGGetOnlineDisplayList` and must be ignored, or
  an accessory connecting then would be learned for it.
- Right after a lid-open wake, the display list briefly still showed the monitor from before the
  sleep; the MacBook started pairing the keyboard another Mac was using until the list caught up
  (`pairing stopped` 0.3 s later). Claims now wait 1.5 s after a wake.

**Fix.** On wake, a closed MacBook with `AppleClamshellCausesSleep` false declares user activity,
which wakes it fully; the same condition cancels idle sleep.

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
