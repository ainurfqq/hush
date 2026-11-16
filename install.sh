#!/usr/bin/env bash
# Hush installer: builds from source on your Mac and installs to ~/Applications. No Xcode, no Apple account.
#
#   curl -fsSL https://raw.githubusercontent.com/ainurfqq/hush-meetings/main/install.sh | bash
#   (from a clone:  bash install.sh)
#
# Options (environment): HUSH_REF=<branch|tag> (default main) · HUSH_SKIP_MODELS=1 · HUSH_SMALL_MODEL=1
#                        HUSH_APPS_DIR=<dir> (default ~/Applications) · HUSH_BIN_DIR=<dir> (default ~/.local/bin)
set -euo pipefail

REPO="${HUSH_REPO:-ainurfqq/hush-meetings}"
REF="${HUSH_REF:-main}"
DATA="$HOME/Library/Application Support/Hush"
APPS="${HUSH_APPS_DIR:-$HOME/Applications}"
BIN="${HUSH_BIN_DIR:-$HOME/.local/bin}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
step() { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
die()  { printf '\n\033[1;31mHush install stopped:\033[0m %s\n' "$*" >&2; exit 1; }

bold "Hush: local meeting notes for macOS"

step "Checking this Mac"
[ "$(uname -s)" = "Darwin" ] || die "Hush runs on macOS only."
[ "$(uname -m)" = "arm64" ] || die "Hush v0.1 needs an Apple Silicon Mac (M1 or newer)."
OSV="$(sw_vers -productVersion)"; MAJ="${OSV%%.*}"; MIN="$(echo "$OSV" | cut -d. -f2)"
if [ "$MAJ" -lt 14 ] || { [ "$MAJ" -eq 14 ] && [ "${MIN:-0}" -lt 4 ]; }; then die "macOS 14.4 or newer is needed (system-audio capture API). You have $OSV."; fi
echo "  macOS $OSV, $(sysctl -n machdep.cpu.brand_string), $(( $(sysctl -n hw.memsize) / 1073741824 )) GB RAM"

if ! xcode-select -p >/dev/null 2>&1 || ! command -v swiftc >/dev/null 2>&1; then
  xcode-select --install >/dev/null 2>&1 || true
  die "Apple's Command Line Tools are needed to build Hush (free, ~1 GB, no Xcode).
  A window to install them has opened. When it finishes, run this installer again."
fi
echo "  Swift: $(swiftc --version 2>&1 | head -1 | sed 's/.*Apple Swift version /Swift /')"

if ! command -v brew >/dev/null 2>&1 && [ ! -x /opt/homebrew/bin/brew ]; then
  die "Homebrew is needed for the speech engine (whisper.cpp). Install it from https://brew.sh, then run this installer again."
fi
command -v brew >/dev/null 2>&1 || eval "$(/opt/homebrew/bin/brew shellenv)"

step "Getting the source"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || true)"
if [ -n "$HERE" ] && [ -f "$HERE/scripts/build.sh" ] && [ -f "$HERE/Sources/Core/MCPServer.swift" ]; then
  SRC="$HERE"; echo "  using local checkout $SRC"
else
  SRC="$DATA/src"
  mkdir -p "$DATA"
  if [ -d "$SRC/.git" ]; then
    git -C "$SRC" fetch -q origin "$REF" && git -C "$SRC" checkout -q -B "$REF" FETCH_HEAD
  else
    rm -rf "$SRC"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      gh repo clone "$REPO" "$SRC" -- -q --depth 1 --branch "$REF"
    else
      git clone -q --depth 1 --branch "$REF" "https://github.com/$REPO.git" "$SRC" \
        || die "Could not download $REPO. If the repo is private, install GitHub CLI (brew install gh), run 'gh auth login', and try again."
    fi
  fi
  echo "  $SRC @ $(git -C "$SRC" rev-parse --short HEAD)"
fi

if [ "${HUSH_NO_LOCAL_CERT:-0}" != "1" ]; then
  step "Local signing certificate (keeps macOS permissions across updates)"
  bash "$SRC/scripts/make-signing-cert.sh" || echo "  skipped: could not create the local certificate; using ad-hoc signing"
fi

step "Building (about 1-2 minutes)"
bash "$SRC/scripts/build.sh"

step "Installing to $APPS"
osascript -e 'tell application id "app.airo.hush" to quit' >/dev/null 2>&1 || true
pkill -f "Hush.app/Contents/MacOS/Hush" >/dev/null 2>&1 || true
mkdir -p "$APPS" "$BIN"
rm -rf "$APPS/Hush.app"
cp -R "$SRC/build/Hush.app" "$APPS/Hush.app"
# Built locally, so there is no quarantine flag; clear it anyway in case the folder was copied from a download.
xattr -dr com.apple.quarantine "$APPS/Hush.app" 2>/dev/null || true
ln -sf "$APPS/Hush.app/Contents/MacOS/hush-cli" "$BIN/hush"
echo "  app: $APPS/Hush.app"
echo "  cli: $BIN/hush"
case ":$PATH:" in *":$BIN:"*) ;; *) echo "  note: add $BIN to your PATH to type 'hush' anywhere (echo 'export PATH=\"$BIN:\$PATH\"' >> ~/.zshrc)";; esac

if [ "${HUSH_SKIP_MODELS:-0}" != "1" ]; then
  step "Downloading the local speech engines and models (~800 MB, checked with SHA-256)"
  bash "$APPS/Hush.app/Contents/Resources/fetch-engines.sh"
fi

step "Checking"
"$APPS/Hush.app/Contents/MacOS/hush-cli" doctor || echo "  (some parts are missing; see above)"

bold "
Hush is installed."
cat <<EOF

  Start it:        open "$APPS/Hush.app"      (a waveform icon appears in the menu bar)
  First recording: macOS asks for Microphone and for System Audio Recording. Click Allow.
  AI:              Settings → AI provider. Default is the Claude Code CLI ('claude') if you have it.
  Claude Code MCP: claude mcp add --transport stdio --scope user hush -- "$BIN/hush" mcp
  Uninstall:       bash "$SRC/uninstall.sh"

  Please tell people when you record them. Hush keeps everything on this Mac.
EOF
