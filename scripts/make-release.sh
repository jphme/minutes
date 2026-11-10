#!/usr/bin/env bash
# Builds a distributable dist/Minutes-<version>.dmg (Apple Silicon, macOS 15+).
#
# Without an Apple Developer ID the app is signed ad-hoc: it runs, but on first open macOS says it cannot verify
# the developer; users allow it once under System Settings → Privacy & Security → "Open Anyway".
# With a Developer ID (MINUTES_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)") the app gets the hardened
# runtime, and with NOTARY_PROFILE set (created once with `xcrun notarytool store-credentials <profile>`) the DMG is
# notarized and stapled, so it opens without warnings.
#
# Speech models (~0.6 GB) are not bundled; the app downloads them from Hugging Face on first launch.
#
# Usage: scripts/make-release.sh 0.2.0
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/make-release.sh <version>}"
export MINUTES_VERSION="$VERSION"
export MINUTES_SIGN_IDENTITY="${MINUTES_SIGN_IDENTITY:--}"

scripts/build-app.sh --no-install

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R build.noindex/Minutes.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p dist
DMG="dist/Minutes-$VERSION.dmg"
rm -f "$DMG"
# hdiutil fails now and then with "Resource busy", above all on CI runners; retry a few times.
for attempt in 1 2 3 4 5; do
  if hdiutil create -volname "Minutes $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"; then break; fi
  [ "$attempt" = 5 ] && { echo "hdiutil create failed 5 times" >&2; exit 1; }
  echo "hdiutil create failed (attempt $attempt), retrying" >&2
  rm -f "$DMG"
  sleep $((attempt * 5))
done

if [[ "$MINUTES_SIGN_IDENTITY" == "Developer ID Application"* ]]; then
  codesign --force --timestamp --sign "$MINUTES_SIGN_IDENTITY" "$DMG"
  if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$DMG"
  fi
fi

echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
shasum -a 256 "$DMG"
echo "Publish with: gh release create v$VERSION \"$DMG\" --title \"Minutes $VERSION\" --notes-file <notes.md>"
