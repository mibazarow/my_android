import Foundation
import Combine

/// Состояние зеркалирования.
enum MirrorState: Equatable {
    case idle
    case waitingForDevice
    case running
    case failed(String)
}

/// Держит процесс scrcpy и данные о телефоне.
///
/// Параметры зашиты: 1920 px, 60 fps, H.264, экран не гаснет.
/// Меняется только «поверх других окон» — флаг читается scrcpy лишь при старте,
/// поэтому для его смены процесс перезапускается.
final class MirrorController: ObservableObject {

    static let shared = MirrorController()

    @Published private(set) var state: MirrorState = .idle
    @Published private(set) var devices: [AndroidDevice] = []
    @Published private(set) var battery: AdbService.Battery?
    @Published private(set) var deviceInfo: AdbService.DeviceInfo?
    @Published var settings: MirrorSettings {
        didSet {
            settings.save()
            if settings.alwaysOnTop != oldValue.alwaysOnTop {
                applyAlwaysOnTop()
            }
        }
    }

    /// Окно зеркала закрыли вручную — приложение должно выйти.
    var onWindowClosed: (() -> Void)?

    /// Опрос adb и чтение батареи идут здесь, а не на главном потоке:
    /// `adb devices` — это отдельный процесс, и его ожидание подвешивало меню.
    private let scanQueue = DispatchQueue(label: "ru.bazarow.myandroid.scan", qos: .userInitiated)
    private var scanInFlight = false
    private var lastDetailsSerial: String?
    private var lastDetailsAt = Date.distantPast
    private var lastLaunchAttempt = Date.distantPast

    private var process: Process?
    private var pollTimer: Timer?
    private var restarting = false

    private init() {
        self.settings = MirrorSettings.load()

        MirrorLog.prepare()

        // Прибираем процессы scrcpy, оставшиеся от прошлого запуска.
        // Если приложение в прошлый раз упало или его убили, scrcpy
        // продолжает висеть сиротой и держит окно с телефоном.
        MirrorController.killOrphanedMirrors()

        startPolling()
    }

    // MARK: - Опрос ADB

    private func startPolling() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        // Первый опрос — сразу после старта. start-server может занять
        // несколько секунд, поэтому он тоже уходит в фоновую очередь.
        scanQueue.async { [weak self] in
            DeviceScanner.startADBServer()
            DispatchQueue.main.async {
                self?.refresh()
            }
        }
    }

    /// Опрос устройств, батареи и инфо. Поднимает зеркало, когда телефон готов.
    ///
    /// - Parameter forceDetails: перечитать батарею и модель, не дожидаясь
    ///   десятисекундного интервала (нужно при открытии меню).
    func refresh(forceDetails: Bool = false) {
        scanQueue.async { [weak self] in
            guard let self, !self.scanInFlight else { return }
            self.scanInFlight = true

            let found = DeviceScanner.scan()
            let readySerial = found.first(where: { $0.isReady })?.serial

            var battery: AdbService.Battery?
            var info: AdbService.DeviceInfo?

            let needDetails: Bool
            if let readySerial {
                needDetails = forceDetails
                    || self.lastDetailsSerial != readySerial
                    || Date().timeIntervalSince(self.lastDetailsAt) > 10
                if needDetails {
                    battery = AdbService.battery(serial: readySerial)
                    info = AdbService.deviceInfo(serial: readySerial)
                    self.lastDetailsSerial = readySerial
                    self.lastDetailsAt = Date()
                }
            } else {
                needDetails = false
                self.lastDetailsSerial = nil
            }

            DispatchQueue.main.async {
                if self.devices != found {
                    self.devices = found
                }

                if readySerial == nil {
                    if self.battery != nil { self.battery = nil }
                    if self.deviceInfo != nil { self.deviceInfo = nil }
                } else if needDetails {
                    self.battery = battery
                    self.deviceInfo = info
                }

                self.autostartIfReady()
            }

            self.scanInFlight = false
        }
    }

    var readyDevice: AndroidDevice? {
        devices.first(where: { $0.isReady })
    }

    private func autostartIfReady() {
        guard process == nil, !restarting else { return }

        guard let device = readyDevice else {
            // Телефон отвалился, но окно было открыто: не выходим и не закрываем
            // окно, просто ждём. Иначе дёрнутый кабель убивает приложение.
            if state != .waitingForDevice {
                state = .waitingForDevice
            }
            return
        }

        launch(serial: device.serial)
    }

    // MARK: - Запуск scrcpy

    private func launch(serial: String, force: Bool = false) {
        // Не долбим запуском каждые две секунды, если scrcpy падает сразу.
        if !force, Date().timeIntervalSince(lastLaunchAttempt) <= 2.0 {
            return
        }
        lastLaunchAttempt = Date()

        guard let scrcpy = ToolLocator.scrcpy else {
            state = .failed("Не найден движок зеркалирования внутри приложения")
            return
        }
        guard ToolLocator.adb != nil else {
            state = .failed("Не найден adb внутри приложения")
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: scrcpy)
        task.arguments = settings.arguments(serial: serial)

        // scrcpy вызывает adb по имени: без подмешивания PATH он его не найдёт,
        // потому что GUI-приложение не видит PATH из терминала.
        // environment() также подставляет путь к встроенному scrcpy-server.
        task.environment = ToolLocator.environment()

        // Вывод обязательно вычитываем. Иначе буфер трубы переполняется,
        // scrcpy блокируется на записи и зеркало замирает.
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        MirrorController.drain(stdout)
        MirrorController.drain(stderr)

        task.terminationHandler = { [weak self] finished in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil

            DispatchQueue.main.async {
                guard let self else { return }
                // Старый обработчик мог сработать уже после перезапуска —
                // чужой процесс не должен обнулять новый.
                guard self.process === finished else { return }
                self.process = nil

                if self.restarting {
                    self.restarting = false
                    return
                }

                // Окно закрыли вручную или телефон отключили: код 0/15 либо
                // ненулевой код без устройства на связи. В первом случае выходим,
                // во втором — ждём переподключения.
                let deviceStillThere = self.readyDevice != nil

                if finished.terminationStatus == 0 || finished.terminationStatus == 15 {
                    if deviceStillThere {
                        self.onWindowClosed?()
                    } else {
                        self.state = .waitingForDevice
                    }
                } else if deviceStillThere {
                    self.state = .failed("scrcpy завершился с кодом \(finished.terminationStatus)")
                } else {
                    self.state = .waitingForDevice
                }
            }
        }

        do {
            try task.run()
            self.process = task
            state = .running
        } catch {
            state = .failed("Не удалось запустить зеркало: \(error.localizedDescription)")
        }
    }

    /// Постоянно читает трубу и складывает вывод в журнал.
    private static func drain(_ pipe: Pipe) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            MirrorLog.append(data)
        }
    }

    /// Перезапуск с новыми флагами: scrcpy читает их только при старте.
    private func applyAlwaysOnTop() {
        guard let device = readyDevice, let old = process else { return }

        restarting = true
        process = nil

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            MirrorController.stop(old)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let self, self.restarting else { return }
                self.restarting = false
                self.launch(serial: device.serial, force: true)
            }
        }
    }

    // MARK: - Управление телефоном

    func pressKey(_ key: AdbService.Key) {
        AdbService.press(key, serial: readyDevice?.serial)
    }

    func wakeScreen() {
        AdbService.wake(serial: readyDevice?.serial)
    }

    // MARK: - Остановка

    /// Останавливает scrcpy. Вызывается при выходе из приложения.
    ///
    /// Гарантированно добивает процесс: сначала вежливый SIGTERM, затем
    /// SIGKILL. Без этого при аварийном выходе scrcpy остаётся сиротой
    /// и продолжает висеть в системе.
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        restarting = true

        if let process {
            MirrorController.stop(process)
            self.process = nil
        }

        // На всякий случай добиваем всё, что могло остаться от этого бандла:
        // scrcpy мог успеть породить потомков или пережить предыдущий запуск.
        MirrorController.killOrphanedMirrors()

        // Гасим adb-демон: он остаётся жить после выхода и висит в системе.
        // При следующем запуске он поднимется сам.
        AdbService.killServer()

        MirrorLog.close()
    }

    /// Останавливает процесс: SIGTERM, до 2 секунд ожидания, затем SIGKILL.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }

        process.terminate()

        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }

        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    /// Убивает процессы scrcpy, оставшиеся от прошлых запусков приложения.
    ///
    /// Такие сироты появляются, если приложение упало или было принудительно
    /// закрыто: родитель умирает, а scrcpy продолжает держать окно и adb.
    /// Ищем только процессы из нашего бандла, чтобы не тронуть чужие.
    static func killOrphanedMirrors() {
        guard let scrcpy = ToolLocator.scrcpy else { return }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", scrcpy]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return }

        let myPID = ProcessInfo.processInfo.processIdentifier
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let pid = pid_t(trimmed), pid != myPID, pid > 0 else { continue }
            kill(pid, SIGKILL)
        }
    }
}
