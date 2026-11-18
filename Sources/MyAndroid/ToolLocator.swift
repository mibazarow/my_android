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

    /// Стандартные каталоги с бинарниками. Один список на поиск и на PATH,
    /// чтобы они не разъехались.
    private static let systemBinDirs = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Каталоги, где ищем бинарники.
    private static var searchPaths: [String] {
        var paths: [String] = []

        if let bundledBinDir {
            paths.append(bundledBinDir)
        }

        paths += systemBinDirs

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

    /// Каталог с бинарниками для подмешивания в PATH дочернего процесса.
    /// scrcpy вызывает adb по имени, поэтому adb должен быть виден в PATH.
    private static func pathPrefix() -> String {
        var dirs: [String] = []
        if let scrcpyPath = scrcpy {
            dirs.append((scrcpyPath as NSString).deletingLastPathComponent)
        }
        if let adbPath = adb {
            let dir = (adbPath as NSString).deletingLastPathComponent
            if !dirs.contains(dir) { dirs.append(dir) }
        }
        dirs += systemBinDirs
        dirs += ["/usr/sbin", "/sbin"]
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

        // Иконки окна лежат в бандле, а не в /usr/local/share/icons:
        // иначе scrcpy на каждом старте пишет ошибку в журнал.
        if let resources = Bundle.main.resourceURL {
            let icons = resources.appendingPathComponent("icons").path
            if FileManager.default.fileExists(atPath: icons) {
                env["SCRCPY_ICON_DIR"] = icons
            }
        }

        // SDL_MAC_BACKGROUND_APP здесь сознательно НЕ ставим. С этой
        // переменной SDL объявляет окно scrcpy фоновым приложением, и
        // macOS перестаёт отдавать ему события клавиатуры: мышь и тач
        // работают (другой путь), а набор текста и вставка молча теряются.
        // Цена отказа — иконка scrcpy в Dock рядом с иконкой My Android.


        return env
    }
}
