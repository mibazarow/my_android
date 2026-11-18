#ifndef SC_MAC_ACTIVATION_H
#define SC_MAC_ACTIVATION_H

#include "common.h"

/*
 * Патч HARNES-S для my_android.
 *
 * Убирает иконку процесса из Dock, не отнимая у окна клавиатурный фокус.
 *
 * Зачем: scrcpy линкует AppKit через SDL и регистрируется в системе как
 * обычное GUI-приложение (activationPolicy = regular, 0). В Dock рядом с
 * иконкой приложения-хозяина появляется вторая иконка «scrcpy».
 *
 * Почему не через SDL_MAC_BACKGROUND_APP: этот хинт переводит процесс в
 * статус background app, и macOS перестаёт отдавать окну события
 * клавиатуры — набор текста и вставка перестают работать (проверено
 * живьём). Accessory-политика лишена этого побочного эффекта: процесса
 * нет в Dock, но окно остаётся полноценным и получает фокус ввода.
 *
 * Реализация в mac_activation.m; на остальных платформах — пустышка.
 */
void sc_mac_set_accessory_activation(void);

#endif
