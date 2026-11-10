#!/bin/bash
# Android_Mirror_Start.sh
# Зеркалирует экран Android-телефона на компьютер (scrcpy) + управление с мыши/клавиатуры.
# Готово к использованию как источник в OBS (Захват окна -> scrcpy).

set -e

# ---- Настройки (под себя) ----
# Для стрима на OBS обычно достаточно 1920x60fps h264. Если экран телефона
# должен гаснуть во время трансляции, добавь сюда --turn-screen-off.
SCRCPY_FLAGS=(
  --max-size 1920
  --max-fps 60
  --video-codec h264
  --stay-awake
)

echo "=== Android Mirror ==="

# 0) Найти scrcpy/adb
command -v scrcpy >/dev/null 2>&1 || { echo "scrcpy не установлен. Установи: brew install scrcpy"; exit 1; }
command -v adb >/dev/null 2>&1 || { echo "adb не установлен. Установи: brew install --cask android-platform-tools"; exit 1; }

# 1) Поднять adb-сервер
adb start-server >/dev/null 2>&1 || true

# 2) Дождаться подключения устройства (до 30 сек)
echo "Жду подключения телефона по ADB..."
adb wait-for-device

if ! adb devices | grep -qw "device$"; then
  echo "Телефон не найден. Проверь USB-кабель и подтверди 'Отладку по USB' на телефоне."
  exit 1
fi

echo "Телефон найден, запускаю зеркалирование..."
echo "Чтобы остановить — закрой окно scrcpy или нажми Ctrl+C."
echo ""

# 3) Запустить зеркалирование
exec scrcpy "${SCRCPY_FLAGS[@]}"
