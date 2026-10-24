#!/bin/bash
# Signs Siri+ (widget first, then the app) with the stable "SiriPlus Local Signing" certificate:
#   bash scripts/sign.sh path/to/SiriPlus.app
#
# macOS keeps microphone and screen-recording permissions for an app whose signature it recognises.
# An ad-hoc signature changes with every build, so permissions would reset after each build and update;
# a fixed certificate keeps them. Without the signing keychain the app keeps its ad-hoc signature.
# Create the keychain once with scripts/make-signing-identity.sh.
set -euo pipefail

app="${1:?Usage: scripts/sign.sh <SiriPlus.app>}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
keychain="${SIRIPLUS_SIGNING_KEYCHAIN:-$HOME/Library/Application Support/SiriPlus Signing/signing.keychain-db}"
password="${SIRIPLUS_SIGNING_KEYCHAIN_PASSWORD:-siriplus-local}"

if [ ! -f "$keychain" ]; then
    printf 'Подпись: локальная (нет %s)\n' "$keychain"
    exit 0
fi

security unlock-keychain -p "$password" "$keychain"
identity="$(security find-identity -p codesigning "$keychain" | awk '/SiriPlus Local Signing/ {print $2; exit}')"
if [ -z "$identity" ]; then
    printf 'Подпись: локальная (в %s нет сертификата SiriPlus Local Signing)\n' "$keychain"
    exit 0
fi

sign() {
    codesign --force --sign "$identity" --keychain "$keychain" --options runtime --timestamp=none --entitlements "$2" "$1"
}
widget="$app/Contents/PlugIns/SiriPlusWidget.appex"
[ -d "$widget" ] && sign "$widget" "$project_dir/SiriPlusWidget/SiriPlusWidget.entitlements"
sign "$app" "$project_dir/SiriPlus/Resources/SiriPlus.entitlements"
codesign --verify --deep --strict "$app"
printf 'Подпись: SiriPlus Local Signing (%s)\n' "$identity"
