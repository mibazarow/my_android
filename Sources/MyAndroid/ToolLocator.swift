import Foundation

/// Ищет внешние утилиты (scrcpy, adb).
///
/// Порядок важен: сначала смотрим внутрь бандла — приложение должно работать
/// на чистом Mac без Homebrew. Внешние пути остаются запасным вариантом
/// для разработки.
enum ToolLocator {

    /// Каталог с утилитами внутри бандла.
    private static var bundledBinDir: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent("bin").path
        return FileManager.default.fileExists(atPath: dir) ? dir : nil
    }

    /// Встроенный scrcpy-server (jar для запуска на телефоне).
    static var bundledServerPath: String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let path = resources.appendingPathComponent("scrcpy-server").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// Каталоги, где ищем бинарники.
    private static var searchPaths: [String] {
        var paths: [String] = []

        if let bundledBinDir {
            paths.append(bundledBinDir)
        }

        paths += [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
        ]

        if let envPath = ProcessInfo.processInfo.environment["PATH"] {
            paths += envPath.split(separator: ":").map(String.init)
        }

        return paths
    }

    /// Полный путь к утилите или nil.
    static func locate(_ name: String) -> String? {
        let fm = FileManager.default
        for dir in searchPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    static var scrcpy: String? { locate("scrcpy") }
    static var adb: String? { locate("adb") }

    /// Работаем ли на встроенных бинарниках (а не на Homebrew).
    static var isSelfContained: Bool {
        guard let scrcpy, let bundledBinDir else { return false }
        return scrcpy.hasPrefix(bundledBinDir)
    }

    /// Каталог с бинарниками для подмешивания в PATH дочернего процесса.
    /// scrcpy вызывает adb по имени, поэтому adb должен быть виден в PATH.
    static func pathPrefix() -> String {
        var dirs: [String] = []
        if let scrcpyPath = scrcpy {
            dirs.append((scrcpyPath as NSString).deletingLastPathComponent)
        }
        if let adbPath = adb {
            let dir = (adbPath as NSString).deletingLastPathComponent
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        return dirs.joined(separator: ":")
    }

    /// Окружение для запуска scrcpy: PATH плюс путь к встроенному серверу.
    static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = pathPrefix()

        // Указываем scrcpy на встроенный сервер, иначе он будет искать его
        // в /opt/homebrew/share/scrcpy и на чужом Mac не найдёт.
        if let server = bundledServerPath {
            env["SCRCPY_SERVER_PATH"] = server
        }

        return env
    }

    /// Человекочитаемое состояние окружения — для диагностики.
    static func diagnostics() -> String {
        var lines: [String] = []
        lines.append("режим: \(isSelfContained ? "самодостаточный (всё в бандле)" : "внешние утилиты")")
        lines.append("scrcpy: \(scrcpy ?? "не найден")")
        lines.append("adb:    \(adb ?? "не найден")")
        lines.append("server: \(bundledServerPath ?? "не найден")")
        return lines.joined(separator: "\n")
    }

    /// Запускает `<tool> --version` и возвращает вывод.
    static func version(of tool: String) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["--version"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return "ошибка: \(error.localizedDescription)"
        }
    }
}