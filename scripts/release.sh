#!/usr/bin/env bash
# Publishes a Hush version for Homebrew: tags vX.Y.Z, pushes the tag, computes the source tarball's SHA-256,
# writes Formula/hush.rb into ainurfqq/homebrew-tap and pushes it. No CI secrets needed (uses your gh login).
# Usage: scripts/release.sh 0.1.1
set -euo pipefail
V="${1:?usage: scripts/release.sh X.Y.Z}"; TAG="v$V"
REPO="ainurfqq/hush-meetings"; TAP="ainurfqq/homebrew-tap"
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first." >&2; exit 1; }

# Keep the app and CLI version in step with the tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $V" Resources/Info.plist
sed -i '' "s/public static let version = \"[0-9.]*\"/public static let version = \"$V\"/" Sources/Core/MCPServer.swift
if [ -n "$(git status --porcelain)" ]; then git commit -qam "Release $TAG"; fi
git push -q origin HEAD
git tag -a "$TAG" -m "Hush $V"
git push -q origin "$TAG"

TMP="$(mktemp -d)"
URL="https://github.com/$REPO/archive/refs/tags/$TAG.tar.gz"
# gh's token lets this work while the repo is private; the bytes are the same as the public download.
curl -fsSL -H "Authorization: Bearer $(gh auth token)" -o "$TMP/src.tar.gz" "$URL"
SHA="$(shasum -a 256 "$TMP/src.tar.gz" | awk '{print $1}')"

gh repo clone "$TAP" "$TMP/tap" -- -q
# Commit to the tap with this repo's identity (the GitHub noreply address), never the global git email.
git -C "$TMP/tap" config user.name "$(git config user.name)"
git -C "$TMP/tap" config user.email "$(git config user.email)"
mkdir -p "$TMP/tap/Formula"
sed -e "s|@VERSION@|$V|g" -e "s|@SHA256@|$SHA|g" packaging/homebrew/hush.rb.in > "$TMP/tap/Formula/hush.rb"
( cd "$TMP/tap" && git add Formula/hush.rb && git commit -qm "hush $V" && git push -q )
echo "Released $TAG  sha256=$SHA"
echo "Users update with: brew update && brew upgrade hush"
