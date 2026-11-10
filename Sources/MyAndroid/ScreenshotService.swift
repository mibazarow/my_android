import Foundation
import AppKit

/// Снимок экрана телефона.
///
/// Делается напрямую через `adb exec-out screencap`, а не через окно scrcpy:
/// так снимок получается в родном разрешении телефона, а не в уменьшенном
/// до 1920. Работает и когда зеркалирование выключено.
enum ScreenshotService {

    enum ScreenshotError: LocalizedError {
        case noADB
        case noDevice
        case failed(String)
        case emptyImage

        var errorDescription: String? {
            switch self {
            case .noADB:
                return "adb не найден"
            case .noDevice:
                return "Телефон не подключён"
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        var args = ["exec-out", "screencap", "-p"]
        if let serial, !serial.isEmpty {
            args = ["-s", serial] + args
        }
        process.arguments = args

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw ScreenshotError.failed(error.localizedDescription)
        }

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let message = String(data: stderr.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? "код \(process.terminationStatus)"
            throw ScreenshotError.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        // adb на некоторых системах добавляет CRLF переводы строк, из-за чего
        // PNG получается битым. Проверяем сигнатуру файла.
        guard data.count > 8, data[0] == 0x89, data[1] == 0x50,
              data[2] == 0x4E, data[3] == 0x47
        else {
            throw ScreenshotError.emptyImage
        }

        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser

        let url = desktop.appendingPathComponent(fileName())
        try data.write(to: url)
        return url
    }

    /// `MyAndroid_2026-11-10_15-42-07.png`
    private static func fileName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "MyAndroid_\(formatter.string(from: Date())).png"
    }
}