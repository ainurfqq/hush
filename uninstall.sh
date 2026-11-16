#!/usr/bin/env bash
# Removes Hush. Meetings and models are kept unless you pass --purge.
#   bash uninstall.sh            remove the app, CLI link, MCP registration, Keychain keys
#   bash uninstall.sh --purge    also delete ~/Library/Application Support/Hush (meetings, models, source)
set -euo pipefail
APPS="${HUSH_APPS_DIR:-$HOME/Applications}"
BIN="${HUSH_BIN_DIR:-$HOME/.local/bin}"
DATA="$HOME/Library/Application Support/Hush"

osascript -e 'tell application id "app.airo.hush" to quit' >/dev/null 2>&1 || true
pkill -f "Hush.app/Contents/MacOS/Hush" >/dev/null 2>&1 || true
[ -f "$DATA/whisper-server.pid" ] && kill "$(cat "$DATA/whisper-server.pid")" 2>/dev/null || true

rm -rf "$APPS/Hush.app" && echo "removed $APPS/Hush.app"
[ -L "$BIN/hush" ] && rm -f "$BIN/hush" && echo "removed $BIN/hush"
if command -v claude >/dev/null 2>&1; then claude mcp remove --scope user hush >/dev/null 2>&1 && echo "removed Claude Code MCP entry 'hush'" || true; fi
for a in openai anthropic; do security delete-generic-password -s app.airo.hush -a "$a" >/dev/null 2>&1 && echo "removed Keychain key: $a" || true; done
tccutil reset All app.airo.hush >/dev/null 2>&1 || true

if [ "${1:-}" = "--purge" ]; then
  rm -rf "$DATA" && echo "deleted $DATA (meetings, models, source)"
else
  echo "kept your meetings and models in: $DATA   (run with --purge to delete them)"
fi
echo "whisper.cpp from Homebrew was left installed (brew uninstall whisper-cpp to remove)."
