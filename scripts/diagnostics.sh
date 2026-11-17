#!/bin/zsh
# Collects Poly's journal from every Mac signed into this iCloud account, plus this Mac's own.
# Usage: scripts/diagnostics.sh [folder]   (default: build/diagnostics/<date and time>)
#
# Builds Poly from this checkout and runs it with --export-diagnostics, which writes the files and
# quits without touching Bluetooth or displays (see Poly/System/Journal.swift). A build is used
# rather than the installed copy, which may predate this option and would start a second Poly.
set -euo pipefail
cd "$(dirname "$0")/.."

out=${1:-build/diagnostics/$(date +%Y-%m-%d-%H%M%S)}
mkdir -p "$out"
out=$(cd "$out" && pwd)

xcodebuild -project Poly.xcodeproj -scheme Poly -derivedDataPath build/DerivedData \
    -allowProvisioningUpdates -packageAuthorizationProvider netrc -quiet build
app=build/DerivedData/Build/Products/Debug/Poly.app

# Through LaunchServices, like any launch of Poly (see AGENTS.md); -n even while Poly is running.
open -n -W "$app" --args --export-diagnostics "$out"
ls -l "$out"
