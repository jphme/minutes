#!/usr/bin/env bash
# Builds Minutes.app from the Swift package and installs it to ~/Applications.
#
# Signing: macOS keys microphone and system-audio permissions to the code signature. An ad-hoc
# signature changes with every build, so permissions are asked again after each rebuild. Run
# scripts/create-signing-cert.sh once to create a stable local identity; this script uses it
# automatically when present. MINUTES_SIGN_IDENTITY overrides it: "-" for ad-hoc, or a
# "Developer ID Application: …" identity, which also enables the hardened runtime for notarization.
#
# Usage: scripts/build-app.sh [--no-install] [--open]
set -euo pipefail
cd "$(dirname "$0")/.."

INSTALL=1; OPEN=0
for arg in "$@"; do
  case "$arg" in
    --no-install) INSTALL=0 ;;
    --open) OPEN=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

swift build -c release --product Minutes

# Spotlight skips folders ending in .noindex, so the built copy does not show up next to the installed app.
APP=build.noindex/Minutes.app
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" Resources/Info.plist)
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Minutes "$APP/Contents/MacOS/Minutes"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns THIRD_PARTY_NOTICES.md LICENSE "$APP/Contents/Resources/"
GIT_HASH=$(git rev-parse --short HEAD 2>/dev/null || echo dev)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_HASH" "$APP/Contents/Info.plist"
[ -n "${MINUTES_VERSION:-}" ] && /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MINUTES_VERSION" "$APP/Contents/Info.plist"

IDENTITY="${MINUTES_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ] && security find-certificate -c "Minutes Local Signing" >/dev/null 2>&1; then
  IDENTITY="Minutes Local Signing"
fi
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  echo "Signing ad-hoc (permissions are asked again after each rebuild; see scripts/create-signing-cert.sh)"
  codesign --force --sign - --identifier "$BUNDLE_ID" "$APP"
elif [[ "$IDENTITY" == "Developer ID Application"* ]]; then
  echo "Signing with '$IDENTITY' (hardened runtime, for notarization)"
  codesign --force --options runtime --timestamp --entitlements Resources/Minutes.entitlements \
    --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"
else
  echo "Signing with '$IDENTITY'"
  if ! codesign --force --sign "$IDENTITY" --identifier "$BUNDLE_ID" "$APP"; then
    echo "Signing failed. If macOS showed a keychain prompt for 'codesign', approve it with 'Always Allow'," >&2
    echo "or allow codesign permanently once: security set-key-partition-list -S apple-tool:,apple:,codesign: -s ~/Library/Keychains/login.keychain-db" >&2
    exit 1
  fi
fi

if [ "$INSTALL" = 1 ]; then
  DEST="$HOME/Applications/Minutes.app"
  mkdir -p "$HOME/Applications"
  # Quit a running instance so the new binary is picked up.
  pkill -x Minutes 2>/dev/null && sleep 1 || true
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  echo "Installed to $DEST"
  if [ "$OPEN" = 1 ]; then open "$DEST"; fi
fi
