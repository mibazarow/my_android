import Foundation

/// Работа с файлами телефона через adb: список, скачивание, загрузка.
enum AdbFileService {

    // MARK: - Модель

    struct Entry: Identifiable, Hashable {
        let name: String
        let path: String
        let isDirectory: Bool
        let size: Int64
        let modified: String

        var id: String { path }

        private static let sizeFormatter: ByteCountFormatter = {
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return formatter
        }()

        /// Размер в читаемом виде.
        var sizeText: String {
            if isDirectory { return "—" }
            return Self.sizeFormatter.string(fromByteCount: size)
        }

        /// Иконка для файла.
        var iconName: String {
            if isDirectory { return "folder.fill" }
            let ext = (name as NSString).pathExtension.lowercased()
            switch ext {
            case "jpg", "jpeg", "png", "gif", "webp", "heic", "bmp":
                return "photo"
            case "mp4", "mkv", "avi", "mov", "3gp", "webm":
                return "film"
            case "mp3", "m4a", "opus", "ogg", "wav", "flac":
                return "music.note"
            case "apk":
                return "shippingbox"
            case "pdf":
                return "doc.richtext"
            case "txt", "md", "json", "xml", "log":
                return "doc.text"
            case "zip", "rar", "7z", "tar", "gz":
                return "archivebox"
            default:
                return "doc"
            }
        }
    }

    // MARK: - Ошибки

    enum FileError: LocalizedError {
        case noDevice
        case noAdb
        case listFailed(String)
        case transferFailed(String)

        var errorDescription: String? {
            switch self {
            case .noDevice: return "Телефон не подключён"
            case .noAdb: return "adb не найден"
            case .listFailed(let message): return "Не удалось получить список: \(message)"
            case .transferFailed(let message): return "Ошибка передачи: \(message)"
            }
        }
    }

    // MARK: - Навигация

    /// Стандартные точки входа в файловую систему телефона.
    static let roots: [(title: String, path: String)] = [
        ("Внутренняя память", "/sdcard"),
        ("DCIM", "/sdcard/DCIM"),
        ("Pictures", "/sdcard/Pictures"),
        ("Download", "/sdcard/Download"),
        ("Movies", "/sdcard/Movies"),
        ("Music", "/sdcard/Music"),
        ("Documents", "/sdcard/Documents"),
    ]

    // MARK: - Список файлов

    /// Читает содержимое каталога на телефоне.
    static func list(path: String, serial: String?) throws -> [Entry] {
        guard ToolLocator.adb != nil else { throw FileError.noAdb }
        guard serial != nil else { throw FileError.noDevice }

        // Слэш в конце обязателен: /sdcard — симлинк, и без него `ls -la`
        // показывает саму ссылку вместо содержимого каталога.
        let listingPath = path.hasSuffix("/") ? path : path + "/"
        // adb склеивает аргументы shell-команды через пробел, поэтому путь
        // без кавычек ломается на пробелах и позволяет подставить `;`.
        let output = AdbService.run(
            ["shell", "ls", "-la", shellQuoted(listingPath)],
            serial: serial
        )

        if output.isEmpty {
            throw FileError.listFailed("пустой ответ adb")
        }
        // adb ругается, если каталог недоступен.
        if output.contains("No such file or directory") || output.contains("Permission denied") {
            throw FileError.listFailed(output.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var entries: [Entry] = []
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let raw = String(line)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("total ") { continue }

            // Формат `ls -la`: права ссылки владелец группа размер дата время имя
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 8 else { continue }

            let permissions = String(parts[0])
            guard permissions.count >= 10 else { continue }

            let isDirectory = permissions.hasPrefix("d")
            let isLink = permissions.hasPrefix("l")
            let size = Int64(parts[4]) ?? 0
            let modified = "\(parts[5]) \(parts[6])"
            let name = parts[7...].joined(separator: " ")

            // Пропускаем . и .., а также симлинки-заглушки.
            if name == "." || name == ".." { continue }
            if name.isEmpty { continue }
            if isLink { continue }

            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            entries.append(
                Entry(
                    name: name,
                    path: fullPath,
                    isDirectory: isDirectory,
                    size: size,
                    modified: modified
                )
            )
        }

        // Каталоги сверху, дальше по имени.
        return entries.sorted { left, right in
            if left.isDirectory != right.isDirectory {
                return left.isDirectory
            }
            return left.name.localizedStandardCompare(right.name) == .orderedAscending
        }
    }

    /// Одинарные кавычки для удалённого shell; внутренняя кавычка
    /// экранируется как '\''.
    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Передача файлов

    /// Скачивает файл с телефона в указанное место.
    static func pull(remote: String, to local: URL, serial: String?) throws {
        guard let adb = ToolLocator.adb else { throw FileError.noAdb }
        guard let serial else { throw FileError.noDevice }

        // Убеждаемся, что каталог назначения существует.
        let directory = local.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        try checkTransfer(
            Command.run(adb, ["-s", serial, "pull", remote, local.path])
        )
    }

    /// Загружает файл на телефон.
    static func push(local: URL, to remoteDirectory: String, serial: String?) throws {
        guard let adb = ToolLocator.adb else { throw FileError.noAdb }
        guard let serial else { throw FileError.noDevice }

        try checkTransfer(
            Command.run(adb, ["-s", serial, "push", local.path, remoteDirectory])
        )
    }

    private static func checkTransfer(_ result: CommandResult) throws {
        if let error = result.launchError {
            throw error
        }
        guard result.status != 0 else { return }

        let message = String(data: result.stderr, encoding: .utf8) ?? "код \(result.status)"
        throw FileError.transferFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Куда складывать файлы, перетащенные на окно.
    /// Download — самое предсказуемое место: его видно в файловом менеджере.
    static let defaultUploadDirectory = "/sdcard/Download"

    /// Скачивает файл в точный путь назначения, который выдала система
    /// (Finder для файлового обещания). Сначала качает во временную папку:
    /// если качать сразу в место, где Finder уже создал пустую заготовку,
    /// `adb pull` может повести себя по-разному.
    static func pullForPromise(
        remote: String,
        name: String,
        to destination: URL,
        serial: String?
    ) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory
            .appendingPathComponent("MyAndroidPromise-\(UUID().uuidString)", isDirectory: true)

        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: true)
            let staged = staging.appendingPathComponent(name)
            try pull(remote: remote, to: staged, serial: serial)

            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: staged, to: destination)
            try? fm.removeItem(at: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }
}
