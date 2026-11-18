import Foundation

/// Настройки зеркалирования.
///
/// Осознанно минимальные: разрешение, частота кадров и режим «не гасить экран»
/// зашиты в константы. Пользователю остаётся один переключатель — поверх окон.
struct MirrorSettings: Codable, Equatable {

    // MARK: - Зашитые параметры

    /// Всегда 1920 px по длинной стороне. Окно при этом свободно тянется мышью:
    /// scrcpy масштабирует картинку под размер окна сам.
    static let maxSize = 1920
    /// Всегда 60 кадров.
    static let maxFPS = 60
    /// H.264: у него аппаратное декодирование на macOS через VideoToolbox
    /// и самый отзывчивый аппаратный энкодер на стороне телефона.
    /// H.265 жмёт сильнее, но даёт большую задержку — при 1080p60 это заметно.
    static let videoCodec = "h264"

    // MARK: - Пользовательские настройки

    /// Держать окно телефона поверх остальных окон.
    var alwaysOnTop: Bool = false

    // MARK: - Аргументы scrcpy

    func arguments(serial: String?) -> [String] {
        var args: [String] = [
            "--max-size", String(Self.maxSize),
            "--max-fps", String(Self.maxFPS),
            "--video-codec", Self.videoCodec,
            "--stay-awake",
            // Синхронизация буфера обмена — встроенное поведение scrcpy:
            // отдельного флага включения нет, только --no-clipboard-autosync.
            //
            // --shortcut-mod lalt: ⌘ в scrcpy по умолчанию — модификатор ЕГО
            // шорткатов, поэтому ⌘V перехватывался и до вставки не доходил.
            // Оставляем шорткатом только Option — теперь ⌘ вместе со всеми
            // сочетаниями уходит в телефон, и ⌘V работает как вставка.
            "--shortcut-mod", "lalt",
            // --legacy-paste: текст с Mac печатается в поле телефона событиями
            // клавиатуры, а не подкладывается в буфер обмена Android.
            // На Android 12+ буфер доступен только приложению в фокусе, а
            // scrcpy живёт под оболочкой (uid 2000) — обычная вставка молча
            // не срабатывает. Именно этот флаг делает ⌘V надёжным.
            "--legacy-paste",

            // --keyboard=uhid: телефон видит Mac как настоящую физическую
            // клавиатуру (Linux UHID), а не получает синтетические события
            // через системный API Android. Режим sdk (дефолт scrcpy) на
            // Android 16 доходит до IME, но не до полей ввода внутри
            // приложений — набирать текст некуда. Клики и скролл при этом
            // работают: они идут другим каналом, поэтому симптом выглядит
            // так, будто сломана только клавиатура.
            "--keyboard=uhid",


            // Заголовок окна — чтобы в списке окон было понятно, что это телефон.
            "--window-title", "My Android",
            // Куда scrcpy кладёт файлы, перетащенные на окно телефона.
            // Download предсказуем: его видно в любом файловом менеджере.
            "--push-target", "/sdcard/Download/",
        ]

        if alwaysOnTop {
            args.append("--always-on-top")
        }
        if let serial, !serial.isEmpty {
            args += ["--serial", serial]
        }

        return args
    }

    // MARK: - Хранение

    private static let defaultsKey = "MirrorSettings.v2"

    static func load() -> MirrorSettings {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let decoded = try? JSONDecoder().decode(MirrorSettings.self, from: data)
        else {
            return MirrorSettings()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }
}