import Foundation

/// Подключённое Android-устройство.
struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String?
    let product: String?
    let transportID: String?

    var id: String { serial }

    /// Отображаемое имя: модель + серийник, чтобы различать одинаковые телефоны.
    var displayName: String {
        let name = model ?? product ?? "Android"
        return "\(name) (\(serial))"
    }

    var isReady: Bool { state == "device" }

    var stateTitle: String {
        switch state {
        case "device": return "готов"
        case "unauthorized": return "не авторизован — подтверди отладку на телефоне"
        case "offline": return "офлайн"
        case "no permissions": return "нет прав доступа"
        default: return state
        }
    }
}

/// Опрашивает adb на список устройств.
enum DeviceScanner {

    /// Возвращает список устройств. Пустой массив при ошибке или отсутствии.
    static func scan() -> [AndroidDevice] {
        guard let adb = ToolLocator.adb else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["devices", "-l"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return [] }

        return parse(output)
    }

    /// Разбирает вывод `adb devices -l`.
    ///
    /// Формат строки:
    /// `3B664A01CVY00000  device usb:17956864X product:CPH2795 model:CPH2795 device:OP6135L1 transport_id:1`
    static func parse(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []

        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("List of devices") { continue }
            if trimmed.hasPrefix("*") { continue }

            // Серийник и состояние — первые два поля. adb разделяет их
            // пробелами или табами в зависимости от версии, поэтому режем
            // по любому whitespace.
            let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 2 else { continue }

            let serial = String(parts[0])
            let state = String(parts[1])

            var model: String?
            var product: String?
            var transportID: String?

            for field in parts.dropFirst(2) {
                let text = String(field)
                if let value = value(after: "model:", in: text) {
                    model = value
                } else if let value = value(after: "product:", in: text) {
                    product = value
                } else if let value = value(after: "transport_id:", in: text) {
                    transportID = value
                }
            }

            devices.append(AndroidDevice(
                serial: serial,
                state: state,
                model: model,
                product: product,
                transportID: transportID
            ))
        }

        return devices
    }

    private static func value(after prefix: String, in text: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        return String(text.dropFirst(prefix.count))
    }

    /// Запускает adb start-server, чтобы сервер был готов к подключению.
    static func startADBServer() {
        guard let adb = ToolLocator.adb else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["start-server"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
    }
}