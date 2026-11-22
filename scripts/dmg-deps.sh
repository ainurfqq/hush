#!/usr/bin/env bash
# Gets the two extra pieces the DMG build carries, into .cache/ (git-ignored):
#   .cache/bin/whisper-server   whisper.cpp built from source as one file (Metal inside, no Homebrew needed)
#   .cache/Sparkle.framework    Sparkle, for in-app updates (+ .cache/sparkle-bin/ tools for signing updates)
# Pinned versions. Safe to re-run. Usage: scripts/dmg-deps.sh
set -euo pipefail
cd "$(dirname "$0")/.."
WHISPER_TAG="v1.9.5"
SPARKLE_VER="2.10.1"; SPARKLE_SHA="1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27"
mkdir -p .cache/bin

if [ ! -x .cache/bin/whisper-server ]; then
  echo "==> whisper.cpp $WHISPER_TAG (from source)"
  [ -d .cache/whisper.cpp ] || git clone -q --depth 1 --branch "$WHISPER_TAG" https://github.com/ggml-org/whisper.cpp .cache/whisper.cpp
  cmake -S .cache/whisper.cpp -B .cache/whisper.cpp/build -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_BLAS=ON -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_SDL2=OFF -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 -DCMAKE_OSX_ARCHITECTURES=arm64 >/dev/null
  cmake --build .cache/whisper.cpp/build -j 8 --target whisper-server >/dev/null
  cp .cache/whisper.cpp/build/bin/whisper-server .cache/bin/whisper-server
fi
# Must only use system libraries, or it breaks on Macs without Homebrew.
if otool -L .cache/bin/whisper-server | tail -n +2 | grep -vqE '^\s+(/usr/lib/|/System/)'; then
  echo "whisper-server links a non-system library" >&2; exit 1
fi

if [ ! -d .cache/Sparkle.framework ]; then
  echo "==> Sparkle $SPARKLE_VER"
  T="$(mktemp -d)"
  curl -fsSL -o "$T/s.tar.xz" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VER/Sparkle-$SPARKLE_VER.tar.xz"
  [ "$(shasum -a 256 "$T/s.tar.xz" | awk '{print $1}')" = "$SPARKLE_SHA" ] || { echo "Sparkle SHA-256 mismatch" >&2; exit 1; }
  tar -xf "$T/s.tar.xz" -C "$T"
  cp -R "$T/Sparkle.framework" .cache/Sparkle.framework
  mkdir -p .cache/sparkle-bin && cp "$T/bin/sign_update" "$T/bin/generate_keys" .cache/sparkle-bin/
fi
echo "==> DMG extras ready in .cache/"
