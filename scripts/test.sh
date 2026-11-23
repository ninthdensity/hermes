#!/bin/bash
# Runs the full Hermes test suite: Rust unit tests, Swift HermesKitTests,
# and bundle-backed HermesAppHarness (so NSDocumentController & Finder file drop checks run).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

echo "==> Rust core tests"
(cd "$ROOT/core" && cargo test)

echo "==> Building Rust release core"
(cd "$ROOT/core" && cargo build --release --quiet)

echo "==> Swift HermesKitTests"
(cd "$ROOT" && swift run HermesKitTests)

echo "==> Swift HermesAppHarness (bundled)"
(cd "$ROOT" && swift build --product HermesAppHarness)
BIN="$(cd "$ROOT" && swift build --show-bin-path)/HermesAppHarness"

TMPDIR_HARNESS="$(mktemp -d /tmp/hermes-test-harness.XXXXXX)"
trap 'rm -rf "$TMPDIR_HARNESS"' EXIT

BUNDLE="$TMPDIR_HARNESS/Hermes Test Harness.app"
mkdir -p "$BUNDLE/Contents/MacOS"
cp "$ROOT/Resources/Info.plist" "$BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleExecutable HermesAppHarness" \
    -c "Set :CFBundleIdentifier dev.hermes.test-harness" \
    "$BUNDLE/Contents/Info.plist"
cp "$BIN" "$BUNDLE/Contents/MacOS/HermesAppHarness"

"$BUNDLE/Contents/MacOS/HermesAppHarness" "$TMPDIR_HARNESS/output"
