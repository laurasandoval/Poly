#!/bin/zsh
# Builds, signs, notarizes and publishes a Poly release that installed copies update to silently.
# Usage: scripts/release.sh 1.1
#
# One-time setup is in Documentation/Releasing.md. Each release:
#   1. archives Release with the version given and a build number from the commit count,
#   2. exports it signed with Developer ID (with its iCloud provisioning profile),
#   3. notarizes and staples the app, then packs, signs, notarizes and staples Poly.dmg,
#   4. signs Poly.dmg for Sparkle and writes appcast.xml,
#   5. publishes both to a GitHub release in the public releases repository.
#
# For testing without publishing (see Documentation/Releasing.md):
#   METHOD=debugging NOTARIZE=0 PUBLISH=0 FEED_URL=http://127.0.0.1:8765/appcast.xml \
#   DOWNLOAD_URL=http://127.0.0.1:8765/Poly.dmg ED_KEY_FILE=private.key ED_PUBLIC_KEY=… BUILD=9001 scripts/release.sh 9.0.1
set -euo pipefail

version=${1:?usage: scripts/release.sh <version, e.g. 1.1>}
releases_repo=${RELEASES_REPO:-laurasandoval/poly-releases}
feed_url=${FEED_URL:-https://github.com/$releases_repo/releases/latest/download/appcast.xml}
download_url=${DOWNLOAD_URL:-https://github.com/$releases_repo/releases/download/v$version/Poly.dmg}
notary_profile=${NOTARY_PROFILE:-poly-notary}
method=${METHOD:-developer-id}
notarize=${NOTARIZE:-1}
publish=${PUBLISH:-1}

cd "$(dirname "$0")/.."
root=$PWD
out=build/release/$version
derived=build/DerivedData
sparkle=$derived/SourcePackages/artifacts/sparkle/Sparkle/bin
build=${BUILD:-$(git rev-list --count HEAD)}
rm -rf "$out"
mkdir -p "$out"

if [[ $publish == 1 && -n $(git status --porcelain) ]]; then
    echo "Commit or stash changes first: a release is built from what is committed." >&2
    exit 1
fi

xcodebuild -resolvePackageDependencies -project Poly.xcodeproj -scheme Poly -derivedDataPath "$derived" -quiet
if [[ -n ${ED_KEY_FILE:-} ]]; then
    public_key=${ED_PUBLIC_KEY:?ED_PUBLIC_KEY goes with ED_KEY_FILE}
    sign_args=(--ed-key-file "$ED_KEY_FILE")
else
    public_key=$("$sparkle/generate_keys" -p)
    sign_args=()
fi

echo "Archiving Poly $version ($build)…"
xcodebuild archive -project Poly.xcodeproj -scheme Poly -configuration Release \
    -derivedDataPath "$derived" -archivePath "$out/Poly.xcarchive" -allowProvisioningUpdates -quiet \
    MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build" \
    SPARKLE_PUBLIC_KEY="$public_key" POLY_FEED_URL="$feed_url"

echo "Exporting ($method)…"
cat > "$out/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>$method</string>
    <key>signingStyle</key><string>automatic</string>
    <key>teamID</key><string>L3FVAEPEHR</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive -archivePath "$out/Poly.xcarchive" -exportPath "$out/export" \
    -exportOptionsPlist "$out/ExportOptions.plist" -allowProvisioningUpdates -quiet
app=$out/export/Poly.app

if [[ $notarize == 1 ]]; then
    echo "Notarizing the app…"
    ditto -c -k --keepParent "$app" "$out/Poly-notarize.zip"
    xcrun notarytool submit "$out/Poly-notarize.zip" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$app"
fi

echo "Making Poly.dmg…"
mkdir -p "$out/dmg"
ditto "$app" "$out/dmg/Poly.app"
ln -s /Applications "$out/dmg/Applications"
hdiutil create -volname Poly -srcfolder "$out/dmg" -fs HFS+ -format ULFO -ov "$out/Poly.dmg" -quiet
if [[ $notarize == 1 ]]; then
    identity=$(security find-identity -v -p codesigning | grep -o '"Developer ID Application: [^"]*"' | head -1 | tr -d '"')
    codesign --sign "$identity" --timestamp "$out/Poly.dmg"
    xcrun notarytool submit "$out/Poly.dmg" --keychain-profile "$notary_profile" --wait
    xcrun stapler staple "$out/Poly.dmg"
fi

echo "Writing appcast.xml…"
signature=$("$sparkle/sign_update" "${sign_args[@]}" "$out/Poly.dmg")
minimum=$(plutil -extract LSMinimumSystemVersion raw "$app/Contents/Info.plist")
cat > "$out/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Poly</title>
    <item>
      <title>$version</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minimum</sparkle:minimumSystemVersion>
      <enclosure url="$download_url" type="application/octet-stream" $signature />
    </item>
  </channel>
</rss>
EOF

if [[ $publish == 1 ]]; then
    echo "Publishing v$version to $releases_repo…"
    gh release create "v$version" "$out/Poly.dmg" "$out/appcast.xml" \
        --repo "$releases_repo" --title "Poly $version" --notes "${NOTES:-Poly $version}"
    git tag "v$version" && git push origin "v$version"
    echo "Released: https://github.com/$releases_repo/releases/latest/download/Poly.dmg"
else
    echo "Built $root/$out (not published)."
fi
