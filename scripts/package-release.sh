#!/bin/bash
# Builds the release app bundle, signs it, and packages a zip ready for GitHub Releases.
# Usage: scripts/package-release.sh [output-dir]   (default: dist)
# Set SIGN_IDENTITY to a Developer ID to sign for distribution; ad-hoc otherwise.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTDIR="${1:-$ROOT/dist}"
export PATH="$HOME/.cargo/bin:$PATH"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
ZIP_NAME="Hermes-Writer-${VERSION}-macos.zip"
mkdir -p "$OUTDIR"
OUT_ZIP="$OUTDIR/$ZIP_NAME"

(cd "$ROOT/core" && cargo build --release --quiet)
(cd "$ROOT" && swift build -c release --product hermes)
BIN="$(cd "$ROOT" && swift build -c release --show-bin-path)/hermes"

STAGING="$(mktemp -d /tmp/hermes-release.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT

BUNDLE="$STAGING/Hermes Writer.app"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/hermes"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/Logo.png" "$BUNDLE/Contents/Resources/Logo.png"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$BUNDLE"
else
    codesign --force --sign - "$BUNDLE"
fi
codesign --verify --deep --strict "$BUNDLE"

rm -f "$OUT_ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$BUNDLE" "$OUT_ZIP"

echo "$OUT_ZIP"
shasum -a 256 "$OUT_ZIP"
