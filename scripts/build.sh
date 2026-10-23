#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

# An Apple Development certificate keeps macOS permissions (screen recording, microphone) across rebuilds:
# an ad-hoc signature changes with every build. SIGN_IDENTITY overrides the choice; without a certificate, sign ad-hoc.
identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development: [^"]*\)".*/\1/p' | head -1)}"
identity="${identity:--}"
printf 'Подпись: %s\n' "$identity"

xcodebuild \
    -project SiriPlus.xcodeproj \
    -scheme SiriPlus \
    -configuration Debug \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY="$identity" \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build
printf '\nПриложение: %s/build/Build/Products/Debug/SiriPlus.app\n' "$project_dir"
