#!/usr/bin/env bash
# One command for all tests: unit tests, then (if engines are installed) the end-to-end fixture test.
#   scripts/test.sh          unit + e2e
#   scripts/test.sh --unit   unit only (no models needed, ~10 s)
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/obj
echo "==> compiling tests"
swiftc -target arm64-apple-macos14.4 -swift-version 5 -O -module-cache-path build/obj/cache -module-name HushTests \
  Sources/Core/*.swift tests/main.swift -o build/hush-tests
echo "==> unit tests"
build/hush-tests

[ "${1:-}" = "--unit" ] && exit 0

if ! build/Hush.app/Contents/MacOS/hush-cli doctor >/dev/null 2>&1; then
  echo "==> e2e skipped: engines/models missing (run: hush setup)"; exit 0
fi
if [ ! -f tests/fixtures/meeting1.wav ]; then
  if say -v '?' | grep -q '^Damayanti' && say -v '?' | grep -q '^Daniel'; then
    echo "==> generating the fixture audio with macOS voices (not committed: redistribution rights of system-voice audio unverified)"
    (cd tests/fixtures && ./make_meeting.sh meeting1.tsv Damayanti Daniel)
  else
    echo "==> e2e skipped: needs macOS voices Damayanti + Daniel (System Settings → Accessibility → Spoken Content → Manage Voices)"; exit 0
  fi
fi
echo "==> e2e: 5.6 min Indonesian/English two-speaker fixture (no AI, local rules; ~2-3 min)"
E2E_HOME="$(mktemp -d)"
mkdir -p "$E2E_HOME"
# Reuse installed engines/models without copying 700 MB.
REAL="$HOME/Library/Application Support/Hush"
ln -s "$REAL/models" "$E2E_HOME/models"; ln -s "$REAL/engines" "$E2E_HOME/engines"
echo '{"provider":"none"}' > "$E2E_HOME/config.json"
DIR=$(HUSH_HOME="$E2E_HOME" build/Hush.app/Contents/MacOS/hush-cli process tests/fixtures/meeting1.wav --title "e2e fixture" 2>/dev/null | tail -1)
python3 tools/score_meeting.py tests/fixtures/meeting1.tsv tests/fixtures/meeting1.ref.tsv "$DIR/meeting.json" | tee build/e2e-score.txt
ACC=$(grep -oE 'speaker accuracy: [0-9.]+' build/e2e-score.txt | awk '{print $3}')
ITEMS=$(grep -c '^- \[ \]' "$DIR/summary.md" || true)
echo "action items found by local rules: $ITEMS"
rm -rf "$E2E_HOME"
python3 -c "import sys; sys.exit(0 if float('$ACC') >= 80 and $ITEMS >= 3 else 1)" && echo "e2e PASS (speaker accuracy ≥ 80 %, ≥ 3 action items)" || { echo "e2e FAIL"; exit 1; }
