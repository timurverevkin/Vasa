#!/bin/bash
# Creates a stable self-signed code-signing identity in the login keychain so local
# builds of Vasa keep the same signature across rebuilds.
#
# Without this, Xcode signs ad-hoc ("-"): every build gets a new code identity, macOS
# sees a different application, and the Keychain items holding provider API keys ask
# for access again after every rebuild.
#
# Run once:  ./scripts/make-signing-cert.sh
# It asks for your macOS password — adding the certificate to the login keychain and
# marking it trusted both require it.

set -euo pipefail

NAME="${1:-Vasa Local Signing}"
KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity \"$NAME\" already exists — nothing to do."
    exit 0
fi

cat > "$WORK/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no

[ dn ]
CN = ${NAME}

[ ext ]
basicConstraints = critical,CA:false
keyUsage         = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -passout pass: -out "$WORK/identity.p12" >/dev/null 2>&1

echo "Adding \"$NAME\" to the login keychain…"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign -T /usr/bin/security

echo "Marking it trusted for code signing…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

# Let codesign use the private key without a prompt on every build.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "" "$KEYCHAIN" >/dev/null 2>&1 || true

echo
echo "Done. Verify with:  security find-identity -v -p codesigning"
echo "Then build with:    CODE_SIGN_IDENTITY=\"$NAME\" CODE_SIGN_STYLE=Manual xcodebuild ..."
echo "or set the same two values in the target's Signing & Capabilities in Xcode."
