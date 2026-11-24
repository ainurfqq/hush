#!/usr/bin/env bash
# Builds build/Hush-<version>.dmg (whisper-server + Sparkle inside, signed with "Hush Local Signing"),
# signs it for Sparkle and writes docs/appcast.xml so installed copies see the update.
# Usage: scripts/make-dmg.sh            (version comes from Resources/Info.plist)
set -euo pipefail
cd "$(dirname "$0")/.."
REPO="ainurfqq/hush"
V="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
security find-certificate -c "Hush Local Signing" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 \
  || { echo "The DMG must be signed with 'Hush Local Signing' (same certificate every release, or users lose permissions)." >&2; exit 1; }

scripts/dmg-deps.sh
HUSH_DMG=1 scripts/build.sh | tail -2
codesign --verify --deep --strict build/Hush.app
# build.sh falls back to ad-hoc if signing fails (locked keychain): that would cost every user their permissions.
# (Read into a variable first: `codesign | grep -q` fails under pipefail when grep exits early.)
SIGINFO="$(codesign -dvv build/Hush.app 2>&1)"
[[ "$SIGINFO" == *"Authority=Hush Local Signing"* ]] \
  || { echo "Hush.app is not signed with 'Hush Local Signing' (keychain locked?). Not making the DMG." >&2; exit 1; }

DMG="build/Hush-$V.dmg"; STAGE="build/dmg-stage"
[ -e "$STAGE" ] && mv "$STAGE" "build/.old-stage-$$"
mkdir -p "$STAGE"
cp -R build/Hush.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
[ -e "$DMG" ] && mv "$DMG" "build/.old-$$.dmg"
hdiutil create -quiet -volname "Hush $V" -srcfolder "$STAGE" -fs HFS+ -format UDZO "$DMG"

# EdDSA signature: installed copies refuse any update that is not signed with this key.
SIG="$(.cache/sparkle-bin/sign_update --account hush "$DMG")"   # sparkle:edSignature="…" length="…"
URL="https://github.com/$REPO/releases/download/v$V/Hush-$V.dmg"
cat > docs/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Hush</title>
    <item>
      <title>Hush $V</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$V</sparkle:version>
      <sparkle:shortVersionString>$V</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.4</sparkle:minimumSystemVersion>
      <sparkle:releaseNotesLink>https://github.com/$REPO/releases/tag/v$V</sparkle:releaseNotesLink>
      <enclosure url="$URL" type="application/octet-stream" $SIG />
    </item>
  </channel>
</rss>
XML
echo "==> $DMG ($(du -h "$DMG" | awk '{print $1}')), docs/appcast.xml points at $URL"
