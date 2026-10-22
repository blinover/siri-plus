#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
xcodebuild \
    -project SiriPlus.xcodeproj \
    -scheme SiriPlus \
    -configuration Debug \
    -derivedDataPath build \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build
printf '\nПриложение: %s/build/Build/Products/Debug/SiriPlus.app\n' "$project_dir"
