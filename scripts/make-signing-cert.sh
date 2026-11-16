#!/usr/bin/env bash
# Creates a local, self-signed code-signing identity "Hush Local Signing" in the login keychain.
# Why: ad-hoc signatures change with every build, so macOS treats each update as a new app and
# forgets its Microphone / Screen Recording permissions. A fixed certificate keeps them.
# Free, local to this Mac, not an Apple Developer ID (Gatekeeper still treats the app as unsigned).
set -euo pipefail
NAME="Hush Local Signing"
if security find-certificate -c "$NAME" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1; then
  echo "identity '$NAME' already exists"; exit 0
fi
TMP="$(mktemp -d)"
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -config "$TMP/cfg" 2>/dev/null
PASS="hush-$RANDOM$RANDOM"
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout "pass:$PASS"
security import "$TMP/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign >/dev/null
rm -rf "$TMP"
echo "created '$NAME' in the login keychain"
