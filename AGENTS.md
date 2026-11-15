# Poly agent guide

The canonical guide for every coding agent. There is no CLAUDE.md. Read this and
[the spec](Documentation/Spec.md) (implement it, do not redesign it) before changing anything. The
owner's shared instructions in `~/Developer/agents/instructions.md` also apply; on conflict, the
owner's latest explicit message wins.

**Before writing Swift**, read `~/Developer/agents/references/ios/README.md` and the guide it
routes your task to (usually `apple-engineering.md`), and check live Apple documentation for any
API you are unsure of.

## What Poly is

A macOS menu bar app (no windows) that connects a monitor's Apple keyboard, mouse and trackpad to
the Mac plugged into that monitor and forgets them when it is unplugged, including just before a
closed MacBook sleeps. Each Mac learns its own monitors; Macs never talk to each other.

## Product invariants

1. **The cable is the switch.** Behavior follows which monitors are attached, through one
   idempotent `Switcher.reconcile()`. Add triggers, never a second source of truth.
2. **Release = forget (unpair).** Disconnecting is not enough. Never forget an accessory that did
   not answer while taking it.
3. **Never touch what is not ours.** Only Apple keyboards, mice and trackpads that Poly learned.
4. **Least UI.** One menu bar menu with stock controls and the system's own device artwork. No
   windows, settings or bundled device images. Ask the owner before adding UI.
5. **Sleep is held, briefly.** `prepareForSleep` must finish well inside macOS's 30 s limit.

## Layout

| Path | Owns |
|---|---|
| `Poly/App/PolyApp.swift` | Entry point, `MenuBarExtra` |
| `Poly/Model/Switcher.swift` | All behavior: reconcile, claim, release, sleep, learning |
| `Poly/Model/Monitor.swift` | Saved monitors and accessories, status |
| `Poly/System/Bluetooth.swift` | IOBluetooth: take, forget, recognizing accessories |
| `Poly/System/Displays.swift` | Attached external monitors and their identity |
| `Poly/System/PowerEvents.swift` | Sleep and wake from IOKit power management |
| `Poly/System/SystemIcons.swift` | System artwork for monitors and accessories |
| `Poly/System/Notifier.swift`, `LoginItem.swift` | Notifications, open at login |
| `Poly/Views/MenuContent.swift` | The menu; renders and forwards intents only |
| `Poly/AppIcon.icon` | Icon Composer app icon (SVG layers) |

The project uses folder-synchronized groups: new files under `Poly/` need no project edits.
Swift 6, main-actor default isolation; IOBluetooth and IOKit callbacks arrive on the main run loop.

## Build and verify

```bash
xcodebuild -project Poly.xcodeproj -scheme Poly -derivedDataPath build/DerivedData -allowProvisioningUpdates build
```

`scripts/install.sh` builds Release, installs in /Applications and opens it. Launch the app through
LaunchServices (`open`), not its executable: run from a shell, the shell is responsible for the
Bluetooth permission and TCC kills the process. Do not grant permissions or pair, unpair or
connect the owner's accessories without asking; behavior changes are verified with the spec's
manual test plan on real hardware, by the owner unless they say otherwise.

Do not add tests unless the owner agrees (see the shared instructions). Commit messages are short,
lowercase, subject only.
