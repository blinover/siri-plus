#!/bin/bash
# Creates the self-signed "SiriPlus Local Signing" certificate in its own keychain, outside the
# login keychain, so builds can be signed without prompts:
#   bash scripts/make-signing-identity.sh
#
# For GitHub releases, add two repository secrets (Settings → Secrets and variables → Actions):
#   SIRIPLUS_SIGNING_P12           — the base64 text this script prints
#   SIRIPLUS_SIGNING_P12_PASSWORD  — siriplus (or P12_PASSWORD if you set one)
# Releases signed with the same certificate keep users' macOS permissions across updates.
set -euo pipefail

dir="${SIRIPLUS_SIGNING_DIR:-$HOME/Library/Application Support/SiriPlus Signing}"
keychain="$dir/signing.keychain-db"
keychain_password="${SIRIPLUS_SIGNING_KEYCHAIN_PASSWORD:-siriplus-local}"
p12_password="${P12_PASSWORD:-siriplus}"
mkdir -p "$dir"
cd "$dir"

if [ ! -f signing.p12 ]; then
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
        -subj "/CN=SiriPlus Local Signing" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null
    # macOS `security` cannot read the default PKCS#12 format of OpenSSL 3+.
    openssl pkcs12 -export -legacy -inkey key.pem -in cert.pem -name "SiriPlus Local Signing" \
        -out signing.p12 -passout "pass:$p12_password"
    rm -f key.pem
fi

if [ ! -f "$keychain" ]; then
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import signing.p12 -k "$keychain" -P "$p12_password" -T /usr/bin/codesign
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
fi

security find-identity -p codesigning "$keychain" | grep "SiriPlus Local Signing"
printf '\nBase64 for the SIRIPLUS_SIGNING_P12 secret:\n'
base64 -i signing.p12
