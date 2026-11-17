# Releasing Poly

Poly is distributed outside the Mac App Store (it uses private IOBluetooth calls), signed with the
team's Developer ID, notarized, and updated silently by [Sparkle](https://sparkle-project.org).
Releases are GitHub releases of this public repository; each one holds `Poly.dmg` and the update
feed, `appcast.xml`.

| What | Where |
|---|---|
| Download link to share | `https://github.com/laurasandoval/Poly/releases/latest/download/Poly.dmg` |
| Update feed (built into the app) | `https://github.com/laurasandoval/Poly/releases/latest/download/appcast.xml` |
| Release script | `scripts/release.sh <version>` |
| Updater | `Poly/System/Updater.swift`, Sparkle keys in `Poly-Info.plist` |

GitHub's `releases/latest/download/<file>` always points at the newest non-draft, non-prerelease
release, so every release uploads a fresh `appcast.xml` and `Poly.dmg` and nothing else needs
hosting. To use another repository, change `POLY_FEED_URL` in the project and `RELEASES_REPO` (or
the default in the script) together; copies already installed keep using the old feed.

## How updates behave

- Every 6 hours Poly checks the feed. A newer version is downloaded in the background and checked
  against the EdDSA signature (the public key is built into release builds).
- Poly installs it and relaunches itself, a few seconds' gap, once it is quiet: no pairing,
  connecting or releasing under way, no display change in the last 30 s, not going to sleep, no
  alert waiting for an answer. Otherwise it tries again every minute. Sparkle shows nothing.
- If Poly's copy cannot be replaced without an administrator password (installed by another
  account into /Applications), the update waits silently; **Check for Updates…** shows it.
- **Check for Updates…** shows Sparkle's standard window, the only update UI there is.
- Builds from Xcode and `scripts/install.sh` carry no key, never update, and gray out
  Check for Updates…. Install a release DMG on your own Macs to get updates.

## One-time setup

All of these are the account holder's to do; none are in the repository.

1. **Developer ID Application certificate.** Xcode → Settings → Accounts → the team → Manage
   Certificates → + → Developer ID Application. Only the Account Holder can create it. Keep a
   backup (export it with its private key from Keychain Access).
2. **Notarization credentials.** Create an app-specific password at account.apple.com, then store
   it in the keychain under the profile name the script uses:

   ```bash
   xcrun notarytool store-credentials poly-notary --apple-id <your Apple ID> --team-id L3FVAEPEHR
   ```

3. **Sparkle signing key.** Build once so the Sparkle tools are downloaded, then generate the key;
   it goes into your login keychain and the script reads it from there:

   ```bash
   build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys
   ```

   **Back it up** (`generate_keys -x poly-sparkle-key.txt`, then store the file in a password
   manager and delete it). Every installed copy trusts only this key: losing it means no Mac can
   update again without reinstalling by hand.
4. **Public repository.** `laurasandoval/Poly` is public, and `gh auth status` shows you signed
   in.

## Each release

```bash
scripts/release.sh 1.1
```

From a clean, committed tree. The build number is the commit count, so it always increases. The
script archives, exports with Developer ID (Xcode creates the Developer ID provisioning profile
with the iCloud key-value capability), notarizes and staples the app and the DMG, writes
`appcast.xml`, tags the commit `v1.1` and publishes both to the `v1.1` release. `NOTES="…"` sets the release notes on GitHub; installed copies never show them.

Release outputs stay in `build/release/<version>/` (ignored by Git), including the archive with
its symbols for crash reports.

## Testing an update locally

The update path was tested this way (Learnings, 2026-11-15) and can be repeated after changing
`Updater.swift`. It needs no Developer ID: two builds signed for development, a throwaway key and a
local feed. Quit the installed Poly first; only one Poly should run.

```bash
# A throwaway Ed25519 key: private.key (base64 seed) and its public key.
# (Any Ed25519 tool works; CryptoKit's Curve25519.Signing.PrivateKey().rawRepresentation is the seed.)
for v in "9.0.0 9000" "9.0.1 9001"; do set -- ${=v}
  METHOD=debugging NOTARIZE=0 PUBLISH=0 BUILD=$2 \
  FEED_URL=http://127.0.0.1:8765/appcast.xml DOWNLOAD_URL=http://127.0.0.1:8765/Poly.dmg \
  ED_KEY_FILE=private.key ED_PUBLIC_KEY=$(cat public.key) scripts/release.sh $1
done
(cd build/release/9.0.1 && python3 -m http.server 8765 --bind 127.0.0.1) &
ditto build/release/9.0.0/export/Poly.app /tmp/poly-test/Poly.app
defaults write work.lau.poly SULastCheckTime -date "2000-01-01 00:00:00 +0000"
open /tmp/poly-test/Poly.app   # within seconds it is 9.0.1, relaunched, with nothing shown
```

Afterwards quit it, stop the server, delete the `SU…` keys from `defaults read work.lau.poly`
and reopen the installed Poly.

## Caveats

- **Releasing from another Mac** (0.5 was released from the Mac mini): it needs the Sparkle private
  key imported (`generate_keys -f <exported file>`; check `generate_keys -p` matches the
  `SUPublicEDKey` of the last release), the `poly-notary` profile, and a Developer ID Application
  identity of its own (Xcode → Manage Certificates → +). A `.cer` from another Mac has no private
  key; Xcode's cloud signing still exports the app, but signing `Poly.dmg` needs a local identity.
- **A build that hangs at "Resolve Package Graph"** with `artifacts/` empty is waiting on a
  keychain prompt for package credentials, possibly off screen. Add
  `-packageAuthorizationProvider netrc` to that `xcodebuild` (as `scripts/diagnostics.sh` does).

- Moving a Mac from a development build to the first Developer ID release changes Poly's
  signature, so macOS may ask for Bluetooth permission once more.
- A release cannot be pulled back from Macs that already updated; fix forward with a new version.
- Keep the version rising: Sparkle compares the build number (`sparkle:version`).
