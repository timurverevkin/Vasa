#!/usr/bin/env bash
# Сборка нативного Swift Vasa (.app + .dmg).
#
#   ./scripts/build-native-macos.sh              # arch этой машины
#   ./scripts/build-native-macos.sh arm64
#   ./scripts/build-native-macos.sh x86_64

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "Скрипт нужно запускать на macOS."
  exit 1
fi

ARCH="${1:-}"
if [[ -z "$ARCH" ]]; then
  case "$(uname -m)" in
    arm64) ARCH="arm64" ;;
    x86_64) ARCH="x86_64" ;;
    *) echo "Неизвестная архитектура: $(uname -m)"; exit 1 ;;
  esac
fi

case "$ARCH" in
  arm64|x86_64) ;;
  x64) ARCH="x86_64" ;;
  *) echo "Ожидается arm64 или x86_64 (получено: $1)"; exit 1 ;;
esac

PROJECT="$ROOT/macos/Vasa/Vasa.xcodeproj"
SCHEME="Vasa"
CONFIG="Release"
DERIVED="$ROOT/macos/DerivedData"
OUT="$ROOT/release"
APP_BUILT="$DERIVED/Build/Products/$CONFIG/Vasa.app"

mkdir -p "$OUT" "$DERIVED"

echo "→ xcodebuild ($CONFIG, $ARCH)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIG" \
  -derivedDataPath "$DERIVED" \
  -destination "platform=macOS,arch=$ARCH" \
  ONLY_ACTIVE_ARCH=YES \
  build

if [[ ! -d "$APP_BUILT" ]]; then
  echo "Сборка не удалась: нет $APP_BUILT"
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUILT/Contents/Info.plist" 2>/dev/null || echo "0.0.0")"
DMG_ARCH_LABEL="$ARCH"
if [[ "$ARCH" == "x86_64" ]]; then
  DMG_ARCH_LABEL="x64"
fi
DMG_NAME="Vasa-${VERSION}-${DMG_ARCH_LABEL}-native.dmg"
DMG_PATH="$OUT/$DMG_NAME"
APP_COPY="$OUT/Vasa-native.app"
STAGE="$OUT/.dmg-stage-native"

echo "→ Копирую .app → $APP_COPY"
rm -rf "$APP_COPY"
ditto "$APP_BUILT" "$APP_COPY"

echo "→ DMG $DMG_NAME"
rm -rf "$STAGE"
mkdir -p "$STAGE"
ditto "$APP_BUILT" "$STAGE/Vasa.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG_PATH"

hdiutil create \
  -volname "Vasa" \
  -srcfolder "$STAGE" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  "$DMG_PATH"

rm -rf "$STAGE"

echo
echo "Готово:"
ls -lh "$DMG_PATH" "$APP_COPY"
file "$APP_COPY/Contents/MacOS/Vasa"
echo
echo "open \"$OUT\""
