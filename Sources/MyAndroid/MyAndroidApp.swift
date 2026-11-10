import SwiftUI
import AppKit
import Combine
import UserNotifications

/// Приложение живёт в меню-баре: своего окна у него нет.
/// Экран телефона показывает scrcpy в отдельном окне.
@main
struct MyAndroidApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Пустая сцена: всё управление через NSStatusItem в AppDelegate.
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem?
    private let controller = MirrorController.shared
    private var cancellables: Set<AnyCancellable> = []
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Без иконки в Dock: приложение целиком в меню-баре.
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        observeState()
        updateStatusIcon()

        controller.onWindowClosed = { [weak self] in
            self?.quit()
        }

        controller.refresh()

        // Приложение не имеет окна, поэтому единственный признак запуска —
        // иконка в меню-баре. Без телефона показываем окно-подсказку,
        // иначе кажется, что приложение не запустилось.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.showNoDeviceHintIfNeeded()
        }
    }

    /// Окно-подсказку показываем только если телефона нет.
    /// Контроллер сам себя удерживает, поэтому локальной переменной достаточно.
    private func showNoDeviceHintIfNeeded() {
        guard controller.readyDevice == nil else { return }
        NoDeviceWindowController.present()
    }

    // MARK: - Меню-бар

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = StatusIcon.image()
        item.button?.image?.isTemplate = true
        item.button?.toolTip = "My Android"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu

        statusItem = item
        statusMenu = menu
    }

    /// Пересобирает меню: состав и активность пунктов зависят от состояния.
    private func rebuildMenu() {
        guard let menu = statusMenu else { return }
        menu.removeAllItems()

        let connected = controller.readyDevice != nil
        let running = controller.state == .running

        // 1. Заголовок: модель, версия Android, заряд.
        let header = NSMenuItem(title: headerTitle(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if let info = controller.deviceInfo {
            let sub = NSMenuItem(
                title: "Android \(info.androidVersion) · API \(info.sdk)",
                action: nil,
                keyEquivalent: ""
            )
            sub.isEnabled = false
            menu.addItem(sub)
        }

        menu.addItem(.separator())

        // 2. Поверх других окон
        let onTop = NSMenuItem(
            title: "Поверх других окон",
            action: #selector(toggleAlwaysOnTop),
            keyEquivalent: ""
        )
        onTop.target = self
        onTop.state = controller.settings.alwaysOnTop ? .on : .off
        onTop.isEnabled = running
        menu.addItem(onTop)

        menu.addItem(.separator())

        // 3. Кнопки телефона
        let navHeader = NSMenuItem(title: "Управление", action: nil, keyEquivalent: "")
        navHeader.isEnabled = false
        menu.addItem(navHeader)

        menu.addItem(keyItem("Домой", "house", #selector(pressHome), enabled: connected))
        menu.addItem(keyItem("Назад", "arrow.uturn.backward", #selector(pressBack), enabled: connected))
        menu.addItem(keyItem("Недавние", "square.on.square", #selector(pressRecents), enabled: connected))

        menu.addItem(.separator())

        menu.addItem(keyItem("Громче", "speaker.plus", #selector(volumeUp), enabled: connected))
        menu.addItem(keyItem("Тише", "speaker.minus", #selector(volumeDown), enabled: connected))
        menu.addItem(keyItem("Разбудить экран", "sun.max", #selector(wakeScreen), enabled: connected))

        menu.addItem(.separator())

        // 4. Скриншот
        let shot = NSMenuItem(
            title: "Скриншот на рабочий стол",
            action: #selector(takeScreenshot),
            keyEquivalent: "s"
        )
        shot.target = self
        shot.image = NSImage(systemSymbolName: "camera", accessibilityDescription: "Скриншот")
        shot.isEnabled = connected
        menu.addItem(shot)

        // Файлы: просмотр и перетаскивание в обе стороны.
        let files = NSMenuItem(
            title: "Файлы телефона…",
            action: #selector(showFiles),
            keyEquivalent: "f"
        )
        files.target = self
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Файлы")
        files.isEnabled = connected
        menu.addItem(files)

        menu.addItem(.separator())

        // 5. Выход
        let quitItem = NSMenuItem(
            title: "Выход",
            action: #selector(quit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// Пункт меню с иконкой и обработчиком.
    private func keyItem(
        _ title: String,
        _ symbol: String,
        _ action: Selector,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        return item
    }

    private func headerTitle() -> String {
        switch controller.state {
        case .running:
            guard let device = controller.readyDevice else {
                return "Зеркалирование активно"
            }
            let name = device.model ?? device.product ?? "Android"
            if let battery = controller.battery {
                let charge = battery.charging ? " ⚡︎" : ""
                return "\(name) — \(battery.level)%\(charge)"
            }
            return "\(name) — подключён"

        case .waitingForDevice:
            if controller.devices.isEmpty {
                return "Телефон не подключён"
            }
            return "Жду телефон…"

        case .idle:
            return "Остановлено"

        case .failed(let message):
            return message
        }
    }

    private func observeState() {
        controller.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.rebuildMenu()
                self?.updateStatusIcon()
            }
            .store(in: &cancellables)

        controller.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                self?.rebuildMenu()
                self?.updateStatusIcon()

                // Телефон подключился — подсказка больше не нужна.
                if devices.contains(where: { $0.isReady }) {
                    NoDeviceWindowController.dismissIfNeeded()
                }
            }
            .store(in: &cancellables)

        controller.$battery
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    /// Иконка в меню-баре отражает состояние: подключён / нет / работает.
    private func updateStatusIcon() {
        guard let button = statusItem?.button else { return }

        let connected = controller.readyDevice != nil
        let running = controller.state == .running

        let symbol: String
        if running && connected {
            symbol = "iphone.gen3"
        } else if connected {
            symbol = "iphone.gen3"
        } else {
            symbol = "iphone.slash"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "My Android")
            ?? NSImage(systemSymbolName: "iphone", accessibilityDescription: "My Android")
        image?.isTemplate = true
        button.image = image

        switch controller.state {
        case .running:
            button.toolTip = "My Android — зеркалирование активно"
        case .waitingForDevice:
            button.toolTip = "My Android — телефон не подключён"
        case .idle:
            button.toolTip = "My Android — остановлено"
        case .failed(let message):
            button.toolTip = "My Android — \(message)"
        }
    }

    // MARK: - Действия: настройки

    @objc private func toggleAlwaysOnTop() {
        controller.settings.alwaysOnTop.toggle()
        rebuildMenu()
    }

    // MARK: - Действия: кнопки телефона

    @objc private func pressHome() { controller.pressKey(.home) }
    @objc private func pressBack() { controller.pressKey(.back) }
    @objc private func pressRecents() { controller.pressKey(.recents) }
    @objc private func volumeUp() { controller.pressKey(.volumeUp) }
    @objc private func volumeDown() { controller.pressKey(.volumeDown) }
    @objc private func wakeScreen() { controller.wakeScreen() }

    // MARK: - Действия: скриншот

    @objc private func showFiles() {
        DeviceFilesWindowController.present(serial: controller.readyDevice?.serial)
    }

    @objc private func takeScreenshot() {
        let serial = controller.readyDevice?.serial
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let url = try ScreenshotService.capture(serial: serial)
                DispatchQueue.main.async {
                    self?.post(
                        title: "Скриншот сохранён",
                        body: url.lastPathComponent
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self?.post(
                        title: "Скриншот не получился",
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    // MARK: - Выход

    @objc private func quit() {
        controller.shutdown()
        NSApp.terminate(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        // Обновляем батарею при открытии меню: цифра должна быть свежей.
        controller.refresh()
    }
}

// MARK: - Иконка в меню-баре

enum StatusIcon {

    static func image() -> NSImage {
        if let symbol = NSImage(systemSymbolName: "iphone.gen3", accessibilityDescription: "My Android") {
            return symbol
        }
        if let symbol = NSImage(systemSymbolName: "iphone", accessibilityDescription: "My Android") {
            return symbol
        }

        // Резерв: рисуем простой телефон вручную.
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        let rect = NSRect(x: 5, y: 1, width: 8, height: 16)
        let path = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
        path.lineWidth = 1.4
        NSColor.black.setStroke()
        path.stroke()
        image.unlockFocus()
        return image
    }
}