#!/bin/zsh
# Builds Poly (Release), installs it in /Applications and opens it.
# Usage: scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
derived=build/DerivedData
app="$derived/Build/Products/Release/Poly.app"

build() {
    xcodebuild -project Poly.xcodeproj -scheme Poly -configuration Release \
        -derivedDataPath "$derived" -quiet "$@" build
}

echo "Building Poly…"
if ! build -allowProvisioningUpdates; then
    # No Apple Development certificate for the team on this Mac: sign for this Mac only.
    echo "Signing with the team failed; signing for this Mac only."
    build CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=
fi

echo "Installing in /Applications…"
pkill -x Poly || true
sleep 1
rm -rf /Applications/Poly.app
ditto "$app" /Applications/Poly.app
open /Applications/Poly.app
echo "Poly is running: look for ∞ in the menu bar."
