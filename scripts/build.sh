#!/usr/bin/env bash
# Builds Hush.app and the `hush` CLI with plain swiftc (no SwiftPM, no Xcode needed).
# Output: build/Hush.app (CLI inside at Contents/MacOS/hush-cli). Usage: scripts/build.sh [--debug]
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
OPT="-O"; [ "${1:-}" = "--debug" ] && OPT="-Onone -g"
ARCH="$(uname -m)"
[ "$ARCH" = "arm64" ] || { echo "Hush v0.1 supports Apple Silicon only (got $ARCH)." >&2; exit 1; }
command -v swiftc >/dev/null || { echo "swiftc not found. Install Command Line Tools: xcode-select --install" >&2; exit 1; }

APP="build/Hush.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/obj
TARGET="arm64-apple-macos14.4"
FLAGS=(-target "$TARGET" -swift-version 5 $OPT -module-cache-path build/obj/cache)

echo "==> hush (CLI)"
swiftc "${FLAGS[@]}" -module-name HushCLI Sources/Core/*.swift Sources/CLI/main.swift -o "$APP/Contents/MacOS/hush-cli"

echo "==> Hush (app)"
swiftc "${FLAGS[@]}" -parse-as-library -module-name Hush Sources/Core/*.swift Sources/App/*.swift \
  -framework AppKit -framework SwiftUI -framework AVFoundation -framework CoreAudio -framework Carbon -framework ScreenCaptureKit \
  -o "$APP/Contents/MacOS/Hush"

cp Resources/Info.plist "$APP/Contents/Info.plist"
cp scripts/fetch-engines.sh scripts/engines.lock "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/Fonts" && cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"

# Signing: the local "Hush Local Signing" certificate when present (scripts/make-signing-cert.sh), so macOS keeps
# Microphone / Screen Recording permissions across updates; otherwise ad-hoc. Neither is an Apple Developer ID.
SIGN_ID="$(security find-certificate -c "Hush Local Signing" -Z "$HOME/Library/Keychains/login.keychain-db" 2>/dev/null | awk '/SHA-1 hash:/ {print $3; exit}')"
if [ -n "$SIGN_ID" ]; then
  codesign --force --deep --sign "$SIGN_ID" --identifier app.airo.hush "$APP" >/dev/null && echo "==> signed with Hush Local Signing"
else
  codesign --force --deep --sign - --identifier app.airo.hush "$APP" >/dev/null && echo "==> ad-hoc signed (run scripts/make-signing-cert.sh to keep permissions across updates)"
fi
echo "==> built $ROOT/$APP"
