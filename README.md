# Poly

Your monitor's Magic Keyboard, Mouse and Trackpad follow whichever Mac is plugged into it.

Plug a MacBook into a monitor and that monitor's accessories connect to it. Unplug it (even closed,
in clamshell mode) and they are let go, ready for the next Mac. Any number of Macs and monitors
work this way, with no accounts, network or setup: each Mac only reacts to its own cable.

## Install

On each Mac:

```bash
git clone https://github.com/laurasandoval/Poly.git && Poly/scripts/install.sh
```

The script builds Poly, installs it in /Applications and opens it. Allow Bluetooth when asked. Poly
opens at login from then on and lives in the menu bar as ∞.

## Use

1. Plug into a monitor and connect its keyboard and mouse the usual way, once per Mac (a cable, or
   Bluetooth settings). If they are already connected when Poly starts, there is nothing to do.
2. Poly learns which accessories belong to that monitor and says so in a notification.
3. From then on, plugging in connects them and unplugging lets them go.

If an accessory has been unused for a long time, it may need a click, a key press, or switching
off and on; Poly asks when that happens.

The menu shows each monitor and its accessories. **Forget Accessory** stops Poly managing one and
unpairs it from the Mac.

## How it works

See [the spec](Documentation/Spec.md): the triggers, the take and release sequences, how Poly
learns, and the manual test plan.

Requires macOS 14 or later and Xcode 26 or later to build.
