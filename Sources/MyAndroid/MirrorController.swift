import Foundation
import Combine

/// Состояние зеркалирования.
enum MirrorState: Equatable {
    case idle
    case waitingForDevice
    case running
    case failed(String)

    var title: String {
        switch self {
        case .idle: return "Остановлено"
        case .waitingForDevice: return "Жду телефон…"
        case .running: return "Зеркалирование активно"
        case .failed(let message): return message
        }
    }
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

    private var process: Process?
    private var pollTimer: Timer?
    private var restarting = false
    /// Телефон отваливался — ждём его возвращения, а не выходим.
    private var waitingForReconnect = false

    private init() {
        self.settings = MirrorSettings.load()
        startPolling()
    }

    // MARK: - Опрос ADB

    private func startPolling() {
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            DeviceScanner.startADBServer()
            self?.refresh()
        }
    }

    /// Опрос устройств, батареи и инфо. Поднимает зеркало, когда телефон готов.
    func refresh() {
        let found = DeviceScanner.scan()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.devices != found {
                self.devices = found
            }
            self.autostartIfReady()
        }

        // Батарея и модель меняются редко — читаем в фоне, чтобы не тормозить UI.
        guard let serial = found.first(where: { $0.isReady })?.serial else {
            DispatchQueue.main.async { [weak self] in
                self?.battery = nil
                self?.deviceInfo = nil
            }
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let battery = AdbService.battery(serial: serial)
            let info = AdbService.deviceInfo(serial: serial)
            DispatchQueue.main.async {
                self?.battery = battery
                self?.deviceInfo = info
            }
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
            if case .running = state, waitingForReconnect {
                state = .waitingForDevice
            } else if process == nil {
                state = .waitingForDevice
            }
            return
        }

        waitingForReconnect = false
        launch(serial: device.serial)
    }

    // MARK: - Запуск scrcpy

    private func launch(serial: String) {
        guard let scrcpy = ToolLocator.scrcpy else {
            state = .failed("scrcpy не найден. Установи: brew install scrcpy")
            return
        }
        guard ToolLocator.adb != nil else {
            state = .failed("adb не найден. Установи: brew install --cask android-platform-tools")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: scrcpy)
        process.arguments = settings.arguments(serial: serial)

        // scrcpy вызывает adb по имени: без подмешивания PATH он его не найдёт,
        // потому что GUI-приложение не видит PATH из терминала.
        // environment() также подставляет путь к встроенному scrcpy-server.
        process.environment = ToolLocator.environment()

        process.standardOutput = Pipe()
        process.standardError = Pipe()

        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
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
                        self.waitingForReconnect = true
                        self.state = .waitingForDevice
                    }
                } else if deviceStillThere {
                    self.state = .failed("scrcpy завершился с кодом \(finished.terminationStatus)")
                } else {
                    self.waitingForReconnect = true
                    self.state = .waitingForDevice
                }
            }
        }

        do {
            try process.run()
            self.process = process
            state = .running
        } catch {
            state = .failed("Не удалось запустить scrcpy: \(error.localizedDescription)")
        }
    }

    /// Перезапуск с новыми флагами: scrcpy читает их только при старте.
    private func applyAlwaysOnTop() {
        guard let device = readyDevice, process != nil else { return }

        restarting = true
        process?.terminate()
        process = nil

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.restarting = false
            self?.launch(serial: device.serial)
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

    /// Синхронная остановка для выхода из приложения.
    func shutdown() {
        pollTimer?.invalidate()
        pollTimer = nil
        restarting = true

        guard let process else { return }
        process.terminate()

        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        self.process = nil
    }
}