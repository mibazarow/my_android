#!/usr/bin/env bash
# Сборка собственного бинарника scrcpy из исходников в vendor/scrcpy.
#
# Мы не зависим от версии, которую ставит Homebrew: исходники лежат
# в репозитории, коммит зафиксирован, бинарник собирается здесь и
# кладётся в бандл приложения.
#
# Запуск: ./Tools/build-mirror.sh [--clean]
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

SRC="$ROOT/vendor/scrcpy"
OUT="$ROOT/build/mirror"

if [ ! -d "$SRC" ]; then
    echo "ОШИБКА: нет исходников в $SRC"
    exit 1
fi

if [ "${1:-}" = "--clean" ]; then
    echo "→ чищу прошлую сборку"
    rm -rf "$SRC/builddir" "$SRC/server/build" "$OUT"
fi

# --- Окружение -------------------------------------------------------------

export PATH="/opt/homebrew/bin:$PATH"
export PKG_CONFIG_PATH="/opt/homebrew/lib/pkgconfig:${PKG_CONFIG_PATH:-}"

# Android-часть (Java-сервер для телефона) требует JDK 17-21.
# JDK 26 слишком новый для Android Gradle Plugin.
JAVA_HOME="${JAVA_HOME_SCRCPY:-/opt/homebrew/opt/openjdk@21}"
if [ ! -x "$JAVA_HOME/bin/javac" ]; then
    echo "ОШИБКА: нужен JDK 21. Установи: brew install openjdk@21"
    exit 1
fi
export JAVA_HOME
export PATH="$JAVA_HOME/bin:$PATH"

ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
if [ ! -d "$ANDROID_HOME" ]; then
    echo "ОШИБКА: не найден Android SDK в $ANDROID_HOME"
    exit 1
fi
export ANDROID_HOME

# Gradle ищет SDK через local.properties.
echo "sdk.dir=$ANDROID_HOME" > "$SRC/local.properties"

# --- Проверка инструментов сборочного цикла --------------------------------

for tool in meson ninja javac; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ОШИБКА: нет $tool. Установи: brew install meson ninja openjdk@21"
        exit 1
    fi
done

# --- Сборка ----------------------------------------------------------------

echo "→ настраиваю сборку (meson)"
if [ ! -d "$SRC/builddir" ]; then
    meson setup "$SRC/builddir" "$SRC" \
        --buildtype=release \
        --strip \
        --prefix=/usr/local 2>&1 | tail -12
fi

echo "→ собираю клиент и сервер"
ninja -C "$SRC/builddir"

# --- Проверка результата ---------------------------------------------------

BINARY="$SRC/builddir/app/scrcpy"
SERVER_APK="$SRC/server/build/outputs/apk/release/server-release-unsigned.apk"

if [ ! -x "$BINARY" ]; then
    echo "ОШИБКА: бинарник не собрался: $BINARY"
    exit 1
fi
if [ ! -f "$SERVER_APK" ]; then
    echo "ОШИБКА: сервер не собрался: $SERVER_APK"
    exit 1
fi

# --- Раскладка -------------------------------------------------------------

mkdir -p "$OUT"
cp "$BINARY" "$OUT/scrcpy"
cp "$SERVER_APK" "$OUT/scrcpy-server"

echo "→ проверяю, что бинарник запускается"
"$OUT/scrcpy" --version | head -2

echo ""
echo "=== Готово ==="
echo "клиент: $OUT/scrcpy ($(du -h "$OUT/scrcpy" | cut -f1))"
echo "сервер: $OUT/scrcpy-server ($(du -h "$OUT/scrcpy-server" | cut -f1))"