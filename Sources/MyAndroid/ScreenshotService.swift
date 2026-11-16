import Foundation

/// Снимок экрана телефона.
///
/// Делается напрямую через `adb exec-out screencap`, а не через окно scrcpy:
/// так снимок получается в родном разрешении телефона, а не в уменьшенном
/// до 1920. Работает и когда зеркалирование выключено.
enum ScreenshotService {

    enum ScreenshotError: LocalizedError {
        case noADB
        case failed(String)
        case emptyImage

        var errorDescription: String? {
            switch self {
            case .noADB:
                return "adb не найден"
            case .failed(let message):
                return "adb вернул ошибку: \(message)"
            case .emptyImage:
                return "Телефон вернул пустое изображение"
            }
        }
    }

    /// Снимает экран и кладёт PNG на рабочий стол.
    /// Возвращает URL сохранённого файла.
    @discardableResult
    static func capture(serial: String?) throws -> URL {
        guard let adb = ToolLocator.adb else {
            throw ScreenshotError.noADB
        }

        var args = ["exec-out", "screencap", "-p"]
        if let serial, !serial.isEmpty {
            args = ["-s", serial] + args
        }

        let result = Command.run(adb, args)
        if let error = result.launchError {
            throw ScreenshotError.failed(error.localizedDescription)
        }
        guard result.status == 0 else {
            let message = String(data: result.stderr, encoding: .utf8) ?? "код \(result.status)"
            throw ScreenshotError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let data = result.stdout

        // adb на некоторых системах добавляет CRLF переводы строк, из-за чего
        // PNG получается битым. Проверяем сигнатуру файла.
        guard data.count > 8, data[0] == 0x89, data[1] == 0x50,
              data[2] == 0x4E, data[3] == 0x47
        else {
            throw ScreenshotError.emptyImage
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        // Два снимка в одну секунду не должны затирать друг друга.
        var url = desktop.appendingPathComponent(fileName())
        var attempt = 1
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent(fileName(suffix: attempt))
            attempt += 1
        }

        try data.write(to: url)
        return url
    }

    /// `MyAndroid_2026-11-10_15-42-07.png`
    private static func fileName(suffix: Int? = nil) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let tail = suffix.map { "_\($0)" } ?? ""
        return "MyAndroid_\(formatter.string(from: Date()))\(tail).png"
    }
}