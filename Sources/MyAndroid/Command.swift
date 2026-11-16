import Foundation

/// Результат короткой синхронной команды.
struct CommandResult {
    let status: Int32
    let stdout: Data
    let stderr: Data
    /// Ошибка запуска процесса (нет файла, нет прав). nil, если процесс стартовал.
    let launchError: Error?

    var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
}

/// Запуск коротких команд с параллельным чтением stdout и stderr.
///
/// Если читать одну трубу до конца, а вторая в это время заполнится,
/// процесс заблокируется на записи. Поэтому обе трубы вычитываются
/// одновременно, а результат ждётся через группу.
enum Command {

    static func run(_ tool: String, _ arguments: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            return CommandResult(
                status: -1,
                stdout: Data(),
                stderr: Data(error.localizedDescription.utf8),
                launchError: error
            )
        }

        let group = DispatchGroup()
        let outBox = DataBox()
        let errBox = DataBox()

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outBox.data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        group.wait()
        process.waitUntilExit()

        return CommandResult(
            status: process.terminationStatus,
            stdout: outBox.data,
            stderr: errBox.data,
            launchError: nil
        )
    }
}

/// Каждая труба пишется ровно одним потоком и читается после group.wait().
private final class DataBox {
    var data = Data()
}
