import Foundation

/// Подключённое Android-устройство.
struct AndroidDevice: Identifiable, Hashable {
    let serial: String
    let state: String
    let model: String?
    let product: String?

    var id: String { serial }

    var isReady: Bool { state == "device" }
}

/// Опрашивает adb на список устройств.
enum DeviceScanner {

    /// Возвращает список устройств. Пустой массив при ошибке или отсутствии.
    static func scan() -> [AndroidDevice] {
        guard let adb = ToolLocator.adb else { return [] }

        let result = Command.run(adb, ["devices", "-l"])
        guard result.launchError == nil else { return [] }
        return parse(result.stdoutText)
    }

    /// Разбирает вывод `adb devices -l`.
    ///
    /// Формат строки:
    /// `3B664A01CVY00000  device usb:17956864X product:CPH2795 model:CPH2795 device:OP6135L1 transport_id:1`
    private static func parse(_ output: String) -> [AndroidDevice] {
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

            for field in parts.dropFirst(2) {
                let text = String(field)
                if let value = value(after: "model:", in: text) {
                    model = value
                } else if let value = value(after: "product:", in: text) {
                    product = value
                }
            }

            devices.append(AndroidDevice(
                serial: serial,
                state: state,
                model: model,
                product: product
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
        _ = Command.run(adb, ["start-server"])
    }
}