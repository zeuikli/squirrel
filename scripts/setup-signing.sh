#!/bin/bash
# Create a self-signed code-signing identity so rebuilt Squirrel keeps its
# TCC grants (SPEC §15.9). Ad-hoc signatures change every build, and macOS
# ties Accessibility/Microphone grants to the code signature — a stable
# identity makes grants survive reinstalls.
#
# Usage: scripts/setup-signing.sh [identity-name]   (default: Squirrel Dev Signing)
# Then build with: make release SIGN_IDENTITY="Squirrel Dev Signing"
#
# Note: the trust step may pop a system password prompt (user keychain
# trust settings) — this is expected and required once.

set -euo pipefail

NAME="${1:-Squirrel Dev Signing}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -Fq "$NAME"; then
  echo "identity '$NAME' already exists and is valid — nothing to do"
  exit 0
fi

openssl req -x509 -newkey rsa:2048 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
  -days 3650 -nodes -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

openssl pkcs12 -export -out "$WORK/cert.p12" -inkey "$WORK/key.pem" \
  -in "$WORK/cert.pem" -passout pass:squirrel-signing

security import "$WORK/cert.p12" -k "$KEYCHAIN" -P squirrel-signing \
  -T /usr/bin/codesign -T /usr/bin/security

# Trust the cert for code signing (user domain). May prompt for the login
# keychain password once.
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

echo "---"
security find-identity -v -p codesigning | grep -F "$NAME" || {
  echo "identity imported but not yet valid — open Keychain Access and set"
  echo "the certificate '$NAME' to 'Always Trust' for Code Signing, then re-run."
  exit 1
}
echo "done. build with: make release SIGN_IDENTITY=\"$NAME\""
