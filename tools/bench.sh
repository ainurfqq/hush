#!/usr/bin/env bash
# Times the post-meeting pipeline on the fixture, batched vs one call per turn. No AI (provider none).
# Usage: tools/bench.sh <empty-work-dir>
set -uo pipefail
cd "$(dirname "$0")/.."
B="$1"; R="$HOME/Library/Application Support/Hush"
mkdir -p "$B"; ln -sfn "$R/models" "$B/models"; ln -sfn "$R/engines" "$B/engines"
echo '{"provider":"none"}' > "$B/config.json"
for mode in batch nobatch; do
  NB=0; [ "$mode" = nobatch ] && NB=1
  s=$(date +%s)
  D=$(HUSH_HOME="$B" HUSH_NO_BATCH=$NB build/hush-bench process tests/fixtures/meeting1.wav --title "bench $mode" --no-summary 2>/dev/null | tail -1)
  e=$(date +%s)
  echo "== $mode: $((e-s)) s"
  python3 tools/score_meeting.py tests/fixtures/meeting1.tsv tests/fixtures/meeting1.ref.tsv "$D/meeting.json"
done
