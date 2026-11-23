#!/bin/bash
# Builds the Rust core and Swift app, then installs the signed app in Applications.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# Set SIGN_IDENTITY to a Developer ID to sign for distribution; ad-hoc otherwise.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="/Applications/Hermes Writer.app"
export PATH="$HOME/.cargo/bin:$PATH"

(cd "$ROOT/core" && cargo build --release --quiet)
(cd "$ROOT" && swift build -c "$CONFIG" --product hermes)
BIN="$(cd "$ROOT" && swift build -c "$CONFIG" --show-bin-path)/hermes"

STAGING="$(mktemp -d /Applications/.hermes-build.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
BUNDLE="$STAGING/hermes.app"
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

if [ -e "$APP" ]; then
    mv "$APP" "$STAGING/previous.app"
fi
if ! mv "$BUNDLE" "$APP"; then
    if [ -d "$STAGING/previous.app" ]; then
        mv "$STAGING/previous.app" "$APP"
    fi
    exit 1
fi

# Registers the document types for Finder and the file panels.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"

echo "$APP"
