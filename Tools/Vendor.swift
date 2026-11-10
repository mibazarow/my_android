// Упаковка scrcpy и adb внутрь бандла приложения.
//
// Копирует бинарники и все их несистемные зависимости в Contents/Resources/bin,
// переписывает пути через @loader_path и переподписывает. После этого приложение
// не зависит от Homebrew: его можно перенести на чистый Mac.
//
// Запуск: swift Tools/Vendor.swift "<путь к .app>"

import Foundation

// MARK: - Локатор Homebrew

/// Ищет установленные через Homebrew бинарники и их ресурсы.
///
/// Пути не зашиты жёстко: scrcpy и adb резолвятся через симлинки в bin,
/// а scrcpy-server лежит рядом с настоящим бинарником. Так упаковка
/// переживает обновление версий в Homebrew.
enum Homebrew {

    static let prefix = "/opt/homebrew"

    /// Настоящий путь к бинарнику (с раскрытыми симлинками) или nil.
    static func resolve(_ name: String) -> String? {
        let candidates = [
            "\(prefix)/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        let fm = FileManager.default
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return realPath(candidate)
        }
        return nil
    }

    /// scrcpy-server из той же папки, что и бинарник scrcpy.
    /// Обычно это <cellar>/bin/scrcpy и <cellar>/share/scrcpy/scrcpy-server.
    static func scrcpyServer(for scrcpyBinary: String) -> String? {
        let fm = FileManager.default
        let binDir = URL(fileURLWithPath: scrcpyBinary).deletingLastPathComponent()

        // <cellar>/bin/../share/scrcpy/scrcpy-server
        let candidates = [
            binDir.deletingLastPathComponent()
                .appendingPathComponent("share/scrcpy/scrcpy-server").path,
            "\(prefix)/share/scrcpy/scrcpy-server",
            "\(prefix)/Cellar/scrcpy/4.1_1/share/scrcpy/scrcpy-server",
        ]

        for path in candidates where fm.fileExists(atPath: path) {
            return path
        }
        return nil
    }
}

// MARK: - Утилиты

let systemPrefixes = ["/usr/lib/", "/System/"]

/// Полный путь с раскрытыми симлинками.
func realPath(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// Выполняет команду, возвращает (код, stdout, stderr).
@discardableResult
func run(_ tool: String, _ arguments: [String]) -> (code: Int32, out: String, err: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments

    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError = errPipe

    do {
        try process.run()
    } catch {
        return (-1, "", "не удалось запустить \(tool): \(error.localizedDescription)")
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (
        process.terminationStatus,
        String(data: outData, encoding: .utf8) ?? "",
        String(data: errData, encoding: .utf8) ?? ""
    )
}

/// Несистемные зависимости Mach-O файла.
func dependencies(of path: String) -> [String] {
    let result = run("/usr/bin/otool", ["-L", path])
    guard result.code == 0 else { return [] }

    return result.out
        .split(separator: "\n")
        .dropFirst()
        .compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }
            // Формат: путь (compatibility version ..., current ...)
            guard let range = trimmed.range(of: " (") else { return nil }
            let lib = String(trimmed[trimmed.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            if lib.isEmpty { return nil }
            if systemPrefixes.contains(where: { lib.hasPrefix($0) }) { return nil }
            return lib
        }
}

// MARK: - Упаковка

let fileManager = FileManager.default

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("ОШИБКА: \(message)\n".data(using: .utf8)!)
    exit(1)
}

/// Аргументы командной строки.
let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("Использование: swift Tools/Vendor.swift <путь к .app>")
    exit(1)
}

let appPath = arguments[1]
guard fileManager.fileExists(atPath: appPath) else {
    fail("нет такого бандла: \(appPath)")
}

// MARK: - Поиск исходников

// Клиент и сервер берём из собственной сборки (Tools/build-mirror.sh).
// Так приложение не зависит от того, какая версия scrcpy стоит в Homebrew:
// исходники зафиксированы в vendor/scrcpy, бинарник собирается из них.
let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // Tools
    .deletingLastPathComponent()   // корень проекта
    .path
let mirrorBuild = "\(projectRoot)/build/mirror"

let ownScrcpy = "\(mirrorBuild)/scrcpy"
let ownServer = "\(mirrorBuild)/scrcpy-server"

guard fileManager.isExecutableFile(atPath: ownScrcpy) else {
    fail("""
    нет своей сборки: \(ownScrcpy)
    Сначала собери её: ./Tools/build-mirror.sh
    """)
}
guard fileManager.fileExists(atPath: ownServer) else {
    fail("""
    нет своего сервера: \(ownServer)
    Сначала собери его: ./Tools/build-mirror.sh
    """)
}

guard let adbBinary = Homebrew.resolve("adb") else {
    fail("adb не найден. Установи: brew install --cask android-platform-tools")
}

let scrcpyBinary = ownScrcpy
let serverPath = ownServer

print("→ источники:")
print("   scrcpy: \(scrcpyBinary) (своя сборка)")
print("   adb:    \(adbBinary) (Homebrew)")
print("   server: \(serverPath) (своя сборка)")

// MARK: - Подготовка каталогов

let resourcesDir = (appPath as NSString).appendingPathComponent("Contents/Resources")
let binDir = (resourcesDir as NSString).appendingPathComponent("bin")

if fileManager.fileExists(atPath: binDir) {
    try? fileManager.removeItem(atPath: binDir)
}
do {
    try fileManager.createDirectory(atPath: binDir, withIntermediateDirectories: true)
} catch {
    fail("не удалось создать \(binDir): \(error.localizedDescription)")
}

// MARK: - Сбор зависимостей

print("→ копирую бинарники и зависимости")

/// Имя файла в бандле для каждого исходного пути.
var bundledNames: [String: String] = [:]
/// Размеры для итогового отчёта.
var copiedSizes: [String: Int] = [:]

func copyIntoBundle(_ source: String) {
    let real = realPath(source)
    if bundledNames[real] != nil { return }

    let name = (real as NSString).lastPathComponent
    let target = (binDir as NSString).appendingPathComponent(name)

    if !fileManager.fileExists(atPath: target) {
        do {
            try fileManager.copyItem(atPath: real, toPath: target)
        } catch {
            print("   ! не удалось скопировать \(real): \(error.localizedDescription)")
            return
        }
    }

    bundledNames[real] = name
    if let attributes = try? fileManager.attributesOfItem(atPath: target),
       let size = attributes[.size] as? Int {
        copiedSizes[name] = size
    }
}

copyIntoBundle(scrcpyBinary)
copyIntoBundle(adbBinary)

// Рекурсивно обходим зависимости.
var queue = [scrcpyBinary, adbBinary]
var visited = Set<String>()

while !queue.isEmpty {
    let current = queue.removeFirst()
    let real = realPath(current)
    if visited.contains(real) { continue }
    visited.insert(real)

    for dependency in dependencies(of: real) {
        let dependencyReal = realPath(dependency)
        if bundledNames[dependencyReal] == nil {
            copyIntoBundle(dependencyReal)
            if bundledNames[dependencyReal] != nil {
                queue.append(dependencyReal)
            }
        } else if !visited.contains(dependencyReal) {
            queue.append(dependencyReal)
        }
    }
}

// MARK: - Переписывание путей

print("→ переписываю пути на @loader_path")

// Сначала собственный id каждой библиотеки, потом ссылки на неё.
for (real, name) in bundledNames where name.hasSuffix(".dylib") {
    let target = (binDir as NSString).appendingPathComponent(name)
    run("/usr/bin/install_name_tool", ["-id", "@loader_path/\(name)", target])
}

// Теперь ссылки. Зависимости берём из исходного файла: у скопированного
// они те же, пока мы их не поменяли.
for real in bundledNames.keys {
    let name = bundledNames[real]!
    let target = (binDir as NSString).appendingPathComponent(name)

    for dependency in dependencies(of: real) {
        let dependencyReal = realPath(dependency)
        guard let dependencyName = bundledNames[dependencyReal] else { continue }

        let newReference = "@loader_path/\(dependencyName)"
        if dependency == newReference { continue }

        run("/usr/bin/install_name_tool",
            ["-change", dependency, newReference, target])
    }
}

// MARK: - scrcpy-server

print("→ копирую scrcpy-server")
let serverTarget = (resourcesDir as NSString).appendingPathComponent("scrcpy-server")
do {
    if fileManager.fileExists(atPath: serverTarget) {
        try fileManager.removeItem(atPath: serverTarget)
    }
    try fileManager.copyItem(atPath: serverPath, toPath: serverTarget)
} catch {
    fail("не удалось скопировать scrcpy-server: \(error.localizedDescription)")
}

// MARK: - Подпись

print("→ подписываю")
for name in bundledNames.values {
    let target = (binDir as NSString).appendingPathComponent(name)
    // После install_name_tool старая подпись невалидна, нужна новая.
    run("/usr/bin/codesign", ["--force", "--sign", "-", target])
}

// MARK: - Отчёт и проверка

let totalBytes = copiedSizes.values.reduce(0, +)
let totalMB = Double(totalBytes) / 1024.0 / 1024.0
print(String(format: "→ готово: %d файлов, %.1f MB", bundledNames.count, totalMB))

print("→ проверка зависимостей scrcpy:")
let scrcpyTarget = (binDir as NSString).appendingPathComponent("scrcpy")
let scrcpyDeps = dependencies(of: scrcpyTarget)

var broken: [String] = []
for dependency in scrcpyDeps {
    if dependency.hasPrefix("@loader_path/") {
        let resolved = (binDir as NSString)
            .appendingPathComponent(String(dependency.dropFirst("@loader_path/".count)))
        if fileManager.fileExists(atPath: resolved) {
            print("   ok        \((dependency as NSString).lastPathComponent)")
        } else {
            broken.append(dependency)
            print("   НЕТ ФАЙЛА \(dependency)")
        }
    } else {
        broken.append(dependency)
        print("   ВНЕШНИЙ   \(dependency)")
    }
}

if broken.isEmpty {
    print("   все зависимости внутри бандла")
} else {
    print("ВНИМАНИЕ: \(broken.count) зависимостей не внутри бандла")
    exit(2)
}

// MARK: - Проверка запуска

print("→ проверка: бинарники запускаются")
let versionCheck = run(scrcpyTarget, ["--version"])
if versionCheck.code == 0 {
    let firstLine = versionCheck.out.split(separator: "\n").first.map(String.init) ?? ""
    print("   scrcpy: \(firstLine)")
} else {
    print("   ВНИМАНИЕ: scrcpy не запустился: \(versionCheck.err)")
}

let adbTarget = (binDir as NSString).appendingPathComponent("adb")
let adbCheck = run(adbTarget, ["version"])
if adbCheck.code == 0 {
    let firstLine = adbCheck.out.split(separator: "\n").first.map(String.init) ?? ""
    print("   adb:    \(firstLine)")
} else {
    print("   ВНИМАНИЕ: adb не запустился: \(adbCheck.err)")
}