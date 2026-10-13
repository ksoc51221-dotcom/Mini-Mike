#!/bin/zsh
# One-time setup: a private code-signing identity for Margin, so every build has the same identity
# and macOS keeps its Accessibility / Screen Recording permissions across updates.
#
# It lives in its own keychain file (not your login keychain) and is only used by build.sh.
# Safe to run again.
set -euo pipefail

DIR="$HOME/Library/Application Support/Margin Signing"
KC="$DIR/margin-signing.keychain-db"
CERT="$DIR/margin-signing.cer.pem"
NAME="Margin Local Signing"

mkdir -p "$DIR"
chmod 700 "$DIR"

# The keychain's password only protects this one signing key; build.sh reads it to unlock the keychain.
if [[ ! -f "$DIR/keychain-password" ]]; then
  openssl rand -hex 24 > "$DIR/keychain-password"
  chmod 600 "$DIR/keychain-password"
fi
PW=$(cat "$DIR/keychain-password")

if [[ ! -f "$KC" ]]; then
  security create-keychain -p "$PW" "$KC"
  security set-keychain-settings "$KC" # don't auto-lock
fi
security unlock-keychain -p "$PW" "$KC"

if ! security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/ext.cnf" <<EOF
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
EOF
  openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$CERT" -config "$TMP/ext.cnf" 2>/dev/null
  P12PW=$(openssl rand -hex 16)
  openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$CERT" -out "$TMP/id.p12" \
    -passout "pass:$P12PW" -name "$NAME" 2>/dev/null
  security import "$TMP/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
fi

echo "Signing identity \"$NAME\" is in: $KC"
steps=()
if ! security find-identity -v -p codesigning "$KC" | grep -q "$NAME"; then
  steps+=("security add-trusted-cert -r trustRoot -p codeSign -k \"$KC\" \"$CERT\"")
fi
# codesign only finds identities in keychains on your keychain list.
if ! security list-keychains -d user | grep -qF "$KC"; then
  current=$(security list-keychains -d user | sed -e 's/^ *"//' -e 's/" *$//' | while read -r k; do printf '"%s" ' "$k"; done)
  steps+=("security list-keychains -d user -s $current\"$KC\"")
fi
if (( ${#steps} == 0 )); then
  echo "All set: build.sh will sign with it, and Margin keeps its permissions across updates."
else
  echo
  echo "Left for you (these change your keychain settings, so you run them):"
  for step in "${steps[@]}"; do echo; echo "  $step"; done
fi
