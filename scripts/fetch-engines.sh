#!/usr/bin/env bash
# Downloads Hush's local engines and models into ~/Library/Application Support/Hush and checks SHA-256.
# Safe to re-run: files with the right hash are kept. Set HUSH_SMALL_MODEL=1 to also fetch the 190 MB model.
# Set HUSH_LOCAL_CACHE=<dir> to copy files from a local folder instead of downloading (used in development).
set -euo pipefail
BASE="${HUSH_HOME:-$HOME/Library/Application Support/Hush}"
LOCK="$(dirname "$0")/engines.lock"
mkdir -p "$BASE/models" "$BASE/engines"
say() { printf '  %s\n' "$*"; }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

if ! command -v whisper-server >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/whisper-server ]; then
  if command -v brew >/dev/null 2>&1; then say "installing whisper.cpp with Homebrew…"; brew install whisper-cpp
  else echo "Homebrew is needed for whisper.cpp: https://brew.sh then run: brew install whisper-cpp" >&2; exit 1; fi
fi

grep -v '^#' "$LOCK" | while IFS='|' read -r kind rel url want; do
  [ -z "$kind" ] && continue
  [ "$kind" = "model-optional" ] && [ "${HUSH_SMALL_MODEL:-0}" != "1" ] && continue
  dst="$BASE/$rel"
  if [ -f "$dst" ] && [ "$(sha "$dst")" = "$want" ]; then say "ok   $(basename "$rel")"
  else
    name="$(basename "$rel")"
    if [ -n "${HUSH_LOCAL_CACHE:-}" ] && [ -f "$(find "$HUSH_LOCAL_CACHE" -name "$name" -print -quit)" ]; then
      cp "$(find "$HUSH_LOCAL_CACHE" -name "$name" -print -quit)" "$dst.part"
    else
      say "get  $name"; curl -fL --retry 3 --progress-bar -o "$dst.part" "$url"
    fi
    got="$(sha "$dst.part")"
    if [ "$got" != "$want" ]; then rm -f "$dst.part"; echo "SHA-256 mismatch for $name (got $got)" >&2; exit 1; fi
    mv "$dst.part" "$dst"; say "ok   $name (verified)"
  fi
  if [ "$kind" = "tarball" ]; then tar -xjf "$dst" -C "$(dirname "$dst")"; fi
done
# The prebuilt sherpa-onnx binary comes from a downloaded tarball; clear quarantine in case a browser set it.
xattr -dr com.apple.quarantine "$BASE/engines" 2>/dev/null || true
say "engines ready in $BASE"
