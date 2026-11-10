import Foundation

/// Управление телефоном через ADB: кнопки, батарея, инфо об устройстве.
enum AdbService {

    // MARK: - Запуск команд

    /// Синхронно выполняет `adb <args>` и возвращает stdout.
    @discardableResult
    static func run(_ args: [String], serial: String? = nil) -> String {
        guard let adb = ToolLocator.adb else { return "" }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)

        var fullArgs: [String] = []
        if let serial, !serial.isEmpty {
            fullArgs += ["-s", serial]
        }
        fullArgs += args
        process.arguments = fullArgs

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return ""
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Выполняет команду в фоне, не блокируя интерфейс.
    static func runAsync(_ args: [String], serial: String?, completion: (() -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            run(args, serial: serial)
            if let completion {
                DispatchQueue.main.async(execute: completion)
            }
        }
    }

    // MARK: - Кнопки

    enum Key: Int {
        case home = 3
        case back = 4
        case recents = 187
        case power = 26
        case volumeUp = 24
        case volumeDown = 25
        case mediaPlayPause = 85
        case wakeup = 224
        case sleep = 223
        case enter = 66
    }

    /// Нажатие аппаратной кнопки на телефоне.
    static func press(_ key: Key, serial: String?) {
        runAsync(["shell", "input", "keyevent", String(key.rawValue)], serial: serial)
    }

    // MARK: - Батарея

    struct Battery {
        let level: Int
        let charging: Bool
        let temperature: Double
    }

    /// Читает состояние батареи. nil, если телефон недоступен.
    static func battery(serial: String?) -> Battery? {
        let output = run(["shell", "dumpsys", "battery"], serial: serial)
        guard !output.isEmpty else { return nil }

        func intValue(_ key: String) -> Int? {
            for line in output.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(key + ":") else { continue }
                let raw = trimmed.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
                return Int(raw)
            }
            return nil
        }

        guard let level = intValue("level") else { return nil }

        // status: 2 = charging, 5 = full; плюс признаки питания от USB/AC.
        let status = intValue("status") ?? 0
        let usbPowered = output.contains("USB powered: true")
        let acPowered = output.contains("AC powered: true")
        let charging = status == 2 || status == 5 || usbPowered || acPowered

        // Температура в десятых долях градуса.
        let temp = Double(intValue("temperature") ?? 0) / 10.0

        return Battery(level: level, charging: charging, temperature: temp)
    }

    // MARK: - Информация об устройстве

    struct DeviceInfo {
        let model: String
        let androidVersion: String
        let sdk: String
    }

    static func deviceInfo(serial: String?) -> DeviceInfo? {
        let output = run(
            ["shell", "getprop ro.product.model; getprop ro.build.version.release; getprop ro.build.version.sdk"],
            serial: serial
        )
        let lines = output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }
        return DeviceInfo(
            model: lines[0],
            androidVersion: lines.count > 1 ? lines[1] : "?",
            sdk: lines.count > 2 ? lines[2] : "?"
        )
    }

    /// Включает экран телефона, если он погас.
    static func wake(serial: String?) {
        runAsync(["shell", "input", "keyevent", "224"], serial: serial)
    }
}