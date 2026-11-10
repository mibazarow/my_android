#!/bin/bash
# Сборка My Android.app из исходников.
# Использование: ./build.sh [--run]
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="My Android"
EXEC_NAME="MyAndroid"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

echo "=== Сборка $APP_NAME ==="

# 1) Иконка (генерируется из кода, если ещё нет)
mkdir -p "$BUILD_DIR"
if [ ! -f "$BUILD_DIR/AppIcon.icns" ]; then
    echo "→ рисую иконку"
    swift Tools/IconGen.swift "$BUILD_DIR/icon_1024.png"
    rm -rf "$BUILD_DIR/AppIcon.iconset"
    mkdir -p "$BUILD_DIR/AppIcon.iconset"
    for s in 16 32 128 256 512; do
        sips -z $s $s "$BUILD_DIR/icon_1024.png" \
            --out "$BUILD_DIR/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
        d=$((s*2))
        sips -z $d $d "$BUILD_DIR/icon_1024.png" \
            --out "$BUILD_DIR/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$BUILD_DIR/AppIcon.iconset" -o "$BUILD_DIR/AppIcon.icns"
fi

# 2) Компиляция
echo "→ компилирую Swift"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

swiftc \
    -O \
    -target arm64-apple-macos13.0 \
    -framework AppKit \
    -framework SwiftUI \
    -o "$CONTENTS/MacOS/$EXEC_NAME" \
    Sources/MyAndroid/*.swift

# 3) Ресурсы бандла
echo "→ укладываю ресурсы"
cp Resources/Info.plist "$CONTENTS/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

# Встроенный скрипт зеркалирования — внутри приложения, как просили.
cp Resources/Android_Mirror_Start.sh "$CONTENTS/Resources/Android_Mirror_Start.sh"
chmod +x "$CONTENTS/Resources/Android_Mirror_Start.sh"

# 4) Своя сборка зеркалирующего движка из исходников vendor/scrcpy.
#    Не зависим от версии, которую ставит Homebrew: коммит зафиксирован,
#    бинарник собирается из кода в репозитории.
if [ ! -f build/mirror/scrcpy ] || [ ! -f build/mirror/scrcpy-server ]; then
    echo "→ собираю свой движок из vendor/scrcpy"
    ./Tools/build-mirror.sh
else
    echo "→ движок уже собран (пересобрать: ./Tools/build-mirror.sh --clean)"
fi

# 5) Самодостаточность: движок, adb и все их библиотеки внутрь бандла.
#    Без этого приложение работает только на машине с Homebrew.
echo "→ упаковываю движок и adb внутрь бандла"
swift Tools/Vendor.swift "$APP_DIR"

# 6) Подпись (ad-hoc достаточно для локального запуска)
echo "→ подписываю"
codesign --force --deep --sign - "$APP_DIR" 2>&1 | tail -2

echo "=== Готово: $APP_DIR ==="
du -sh "$APP_DIR"

if [ "${1:-}" = "--run" ]; then
    echo "→ запускаю"
    open "$APP_DIR"
fi