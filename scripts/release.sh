#!/bin/bash
# Builds a Release of Siri+ for Apple silicon and packs it into a disk image:
#   bash scripts/release.sh 0.2.0
# Output: dist/SiriPlus-<version>-arm64.dmg and its .sha256 (the in-app updater checks it).
set -euo pipefail

version="${1:?Usage: scripts/release.sh <version>}"
build_number="${BUILD_NUMBER:-1}"
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"

xcodebuild \
    -project SiriPlus.xcodeproj \
    -scheme SiriPlus \
    -configuration Release \
    -derivedDataPath build \
    ARCHS=arm64 \
    ONLY_ACTIVE_ARCH=NO \
    MARKETING_VERSION="$version" \
    CURRENT_PROJECT_VERSION="$build_number" \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGN_STYLE=Manual \
    DEVELOPMENT_TEAM= \
    build

app="build/Build/Products/Release/SiriPlus.app"
staging="build/dmg"
rm -rf "$staging" && mkdir -p "$staging" dist
ditto "$app" "$staging/SiriPlus.app"
ln -s /Applications "$staging/Applications"

# Without a Developer ID signature macOS quarantines the downloaded app and refuses to open it.
cat > "$staging/Install Siri+.command" <<'EOF'
#!/bin/bash
# Copies Siri+ to Applications and removes the quarantine flag macOS sets on downloaded apps.
set -e
source_app="$(cd "$(dirname "$0")" && pwd)/SiriPlus.app"
pkill -x SiriPlus 2>/dev/null || true
rm -rf /Applications/SiriPlus.app
ditto "$source_app" /Applications/SiriPlus.app
xattr -dr com.apple.quarantine /Applications/SiriPlus.app
open /Applications/SiriPlus.app
echo "Siri+ is installed. You can close this window."
EOF
chmod +x "$staging/Install Siri+.command"

cat > "$staging/README.txt" <<'EOF'
Siri+ — installation / установка

Siri+ has no Apple Developer ID signature, so macOS blocks the downloaded copy.
У Siri+ нет подписи Apple Developer ID, поэтому macOS блокирует скачанную копию.

Option 1 / Вариант 1
  Right-click "Install Siri+.command" → Open → Open.
  Щёлкните правой кнопкой по «Install Siri+.command» → Открыть → Открыть.

Option 2 / Вариант 2
  Drag SiriPlus.app to Applications, then run in Terminal:
  Перетащите SiriPlus.app в «Программы» и выполните в Терминале:

    xattr -dr com.apple.quarantine /Applications/SiriPlus.app

Later updates install from inside the app (menu bar → Check for Updates…).
Следующие версии ставятся из самого приложения (строка меню → Проверить обновления…).
EOF

dmg="dist/SiriPlus-$version-arm64.dmg"
rm -f "$dmg"
hdiutil create -volname "Siri+ $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg"
(cd dist && shasum -a 256 "$(basename "$dmg")" > "$(basename "$dmg").sha256")
printf '\n%s\n' "$dmg"
cat "$dmg.sha256"
