# Сторонние компоненты и лицензии

My Android использует код и библиотеки других проектов. Этот файл — их
перечень, чтобы ничьи права не были нарушены и каждый автор знал, где
искать свой код.

Ниже указано, что мы взяли, под какой лицензией оно распространяется,
где оригинал и что мы с ним сделали.

---

## 1. Движок зеркалирования

### scrcpy

- **Что это:** сервер для телефона и клиент на Mac, которые передают экран
  и ввод через USB.
- **Оригинал:** https://github.com/Genymobile/scrcpy
- **Автор:** Genymobile и участники проекта (contributors)
- **Лицензия:** Apache License 2.0 — полный текст в `vendor/scrcpy/LICENSE`
- **Версия, которую мы взяли:** 4.1, коммит `2926c06c5dc3064ae6d8db706f1a98a37cfcf3f0`
- **Что мы сделали:** форк. Исходники лежат в `vendor/scrcpy/`, мы собираем
  из них собственный бинарник через `Tools/build-mirror.sh`. Изменений
  в самом коде scrcpy мы не вносили — сборка воспроизводит оригинал.
  Если изменения появятся, они будут перечислены здесь.
- **Почему форк, а не зависимость от Homebrew:** чтобы приложение не
  ломалось при обновлении пакетов в системе и не требовало установки
  чего-либо на чужом Mac.

---

## 2. Библиотеки, которые попадают в сборку

Эти библиотеки лежат внутри `.app`. Мы их не изменяли, а распространяем
как есть, вместе с уведомлением об авторских правах.

| Библиотека | Версия | Лицензия | Оригинал |
|---|---|---|---|
| FFmpeg (libavformat, libavcodec, libavutil, libswresample) | 9.0 | **GPL-3.0-or-later** | https://ffmpeg.org/ |
| x264 | r3222 | **GPL-2.0-or-later** | https://www.videolan.org/developers/x264.html |
| x265 | 4.2 | **GPL-2.0-or-later** | https://github.com/Multicorewareinc/x265 |
| SDL3 | 3.4 | Zlib | https://libsdl.org/ |
| libvpx | 1.16.0 | BSD-3-Clause | https://www.webmproject.org/code/ |
| dav1d | 1.5.4 | BSD-2-Clause | https://code.videolan.org/videolan/dav1d |
| opus | 1.6.1 | BSD-3-Clause | https://www.opus-codec.org/ |
| SVT-AV1 | 4.2.0 | BSD-3-Clause | https://gitlab.com/AOMediaCodec/SVT-AV1 |
| mpg123 | 1.33.7 | LGPL-2.1-only | https://www.mpg123.de/ |
| LAME | 4.0 | LGPL-2.0-or-later | https://lame.sourceforge.io/ |
| libusb | 1.0.30 | LGPL-2.1-or-later | https://libusb.info/ |
| OpenSSL | 3.6.3 | Apache-2.0 | https://openssl-library.org |
| XZ Utils (liblzma) | 5.8.3 | 0BSD AND GPL-2.0-or-later | https://tukaani.org/xz/ |

---

## 3. Если ты берёшь FFmpeg или x264 отдельно

FFmpeg в этой сборке собран с поддержкой x264 и x265, поэтому он целиком
попадает под GPL-3.0. То же касается x264 и x265 — они под GPL-2.0.

Если ты хочешь использовать эти библиотеки в проекте с несовместимой
лицензией, тебе нужна сборка FFmpeg в режиме LGPL — без энкодеров
и GPL-компонентов. Готовая инструкция: https://ffmpeg.org/legal.html

---

## 4. ADB (Android Debug Bridge)

- **Что это:** официальный инструмент Android для связи телефона с компьютером.
- **Оригинал:** https://developer.android.com/tools/adb
- **Исходники:** https://android.googlesource.com/platform/packages/modules/adb/
- **Лицензия:** Apache License 2.0
- **Как попадает в сборку:** берётся из `android-platform-tools` (Homebrew cask)
  и кладётся в бандл при сборке. Код не изменяется.

---

## 5. Тексты лицензий

Полные тексты лежат в каталоге `licenses/`:

- `licenses/Apache-2.0.txt` — scrcpy, ADB, OpenSSL
- `licenses/GPL-3.0.txt` — FFmpeg (сборка с GPL-компонентами), само приложение
- `licenses/GPL-2.0.txt` — x264, x265
- `licenses/LGPL-2.1.txt` — mpg123, LAME, libusb
- `licenses/BSD-3-Clause.txt` — libvpx, opus, SVT-AV1
- `licenses/BSD-2-Clause.txt` — dav1d
- `licenses/Zlib.txt` — SDL3
- `licenses/0BSD.txt` — XZ Utils

---

## Лицензия самого My Android

Приложение распространяется под **GNU General Public License v3.0**
(см. `LICENSE`). Она выбрана потому, что в сборке используется FFmpeg
с GPL-компонентами: это единственный вариант, при котором права всех
авторов соблюдены.

Значит, ты можешь свободно брать, менять и распространять это приложение
на тех же условиях — открыто и с сохранением тех же прав для следующих.

---

*Если ты автор одного из проектов выше и считаешь, что что-то указано
неверно, напиши — поправим.*