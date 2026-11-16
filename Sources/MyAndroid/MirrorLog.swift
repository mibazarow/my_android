import Foundation

/// Журнал зеркала: всё, что scrcpy пишет в stdout/stderr, сохраняется в файл.
///
/// Раньше вывод scrcpy уходил в `Pipe()`, который никто не читал. За долгую
/// сессию буфер трубы (64 КБ) переполняется, и scrcpy зависает на записи
/// в лог. Здесь трубы постоянно вычитываются, а текст складывается в
/// `~/Library/Logs/MyAndroid/scrcpy.log` — его можно открыть из меню.
enum MirrorLog {

    static var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library", isDirectory: true)
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("MyAndroid", isDirectory: true)
            .appendingPathComponent("scrcpy.log")
    }

    private static let queue = DispatchQueue(label: "ru.bazarow.myandroid.log")
    private static var handle: FileHandle?
    private static var prepared = false

    /// Создаёт каталог и файл журнала. Повторные вызовы ничего не делают.
    static func prepare() {
        queue.sync {
            guard !prepared else { return }
            prepared = true

            let fm = FileManager.default
            let directory = fileURL.deletingLastPathComponent()
            try? fm.createDirectory(at: directory, withIntermediateDirectories: true)

            // Не даём журналу расти бесконечно: при запуске приложения
            // файл больше 2 МБ начинается заново.
            if let attributes = try? fm.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: fileURL)
            }

            if !fm.fileExists(atPath: fileURL.path) {
                fm.createFile(atPath: fileURL.path, contents: nil)
            }

            handle = try? FileHandle(forWritingTo: fileURL)
            handle?.seekToEndOfFile()
        }
    }

    static func append(_ data: Data) {
        guard !data.isEmpty else { return }
        queue.async {
            guard handle != nil else { return }
            try? handle?.write(contentsOf: data)
        }
    }

    static func close() {
        queue.sync {
            try? handle?.close()
            handle = nil
            prepared = false
        }
    }
}
