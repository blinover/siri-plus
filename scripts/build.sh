#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# An Apple Development certificate keeps macOS permissions (screen recording, microphone) across rebuilds:
# an ad-hoc signature changes with every build. SIGN_IDENTITY overrides the choice; without a certificate, sign ad-hoc.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
identity="${identity:--}"

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
    build -
fi
printf '\nПриложение: %s/build/Build/Products/Debug/SiriPlus.app\n' "$project_dir"
