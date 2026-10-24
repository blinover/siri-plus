#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# A stable signature keeps macOS permissions (screen recording, microphone) across rebuilds; an ad-hoc one
# changes with every build. The "SiriPlus Local Signing" keychain (scripts/make-signing-identity.sh) is used
# when it exists, otherwise an Apple Development certificate. SIGN_IDENTITY overrides the choice.
signing_keychain="${SIRIPLUS_SIGNING_KEYCHAIN:-$HOME/Library/Application Support/SiriPlus Signing/signing.keychain-db}"
if [ -z "${SIGN_IDENTITY:-}" ] && [ -f "$signing_keychain" ]; then
    identity="-"
else
    identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
    identity="${identity:--}"
fi

build() {
    printf 'Подпись: %s\n' "$1"
    xcodebuild \
        -project SiriPlus.xcodeproj \
        -scheme SiriPlus \
        -configuration Debug \
        -derivedDataPath build \
        CODE_SIGN_IDENTITY="$1" \
        CODE_SIGN_STYLE=Manual \
        DEVELOPMENT_TEAM= \
        build
}

# codesign cannot reach the certificate's key from a locked keychain or a non-interactive shell
# (errSecInternalComponent); a locally signed build still runs.
if ! build "$identity" && [ "$identity" != "-" ]; then
    printf '\nПодпись сертификатом не удалась, собираю с локальной подписью.\n'
    identity="-"
    build -
fi
app="$project_dir/build/Build/Products/Debug/SiriPlus.app"
[ "$identity" = "-" ] && bash "$project_dir/scripts/sign.sh" "$app"
printf '\nПриложение: %s\n' "$app"
