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
        // Иконка в Dock: приложение должно быть видно пользователю под своим
        // именем и со своей иконкой. Само зеркало (scrcpy) запускается со
        // скрытой иконкой, поэтому в Dock остаётся ровно один значок — наш.
        NSApp.setActivationPolicy(.regular)

        // Без явного запроса разрешения системные уведомления молча
        // выбрасываются, и «Скриншот сохранён» никогда не появляется.
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
            self?.showNoDeviceHintIfNeeded(attempt: 0)
        }
    }

    /// Окно-подсказку показываем только если телефона нет.
    /// Контроллер сам себя удерживает, поэтому локальной переменной достаточно.
    private func showNoDeviceHintIfNeeded(attempt: Int) {
        guard controller.readyDevice == nil else { return }

        // Холодный `adb start-server` может занять несколько секунд.
        // Ждём результата опроса, чтобы не мигнуть подсказкой зря.
        if controller.devices.isEmpty && controller.state == .idle && attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.showNoDeviceHintIfNeeded(attempt: attempt + 1)
            }
            return
        }

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
        let onTop = addAction(
            "Поверх других окон",
            action: #selector(toggleAlwaysOnTop),
            enabled: running,
            to: menu
        )
        onTop.state = controller.settings.alwaysOnTop ? .on : .off

        menu.addItem(.separator())

        // 3. Кнопки телефона
        let navHeader = NSMenuItem(title: "Управление", action: nil, keyEquivalent: "")
        navHeader.isEnabled = false
        menu.addItem(navHeader)

        addAction("Домой", symbol: "house", action: #selector(pressHome), enabled: connected, to: menu)
        addAction("Назад", symbol: "arrow.uturn.backward", action: #selector(pressBack), enabled: connected, to: menu)
        addAction("Недавние", symbol: "square.on.square", action: #selector(pressRecents), enabled: connected, to: menu)

        menu.addItem(.separator())

        addAction("Громче", symbol: "speaker.plus", action: #selector(volumeUp), enabled: connected, to: menu)
        addAction("Тише", symbol: "speaker.minus", action: #selector(volumeDown), enabled: connected, to: menu)
        addAction("Разбудить экран", symbol: "sun.max", action: #selector(wakeScreen), enabled: connected, to: menu)

        menu.addItem(.separator())

        // 4. Скриншот
        addAction(
            "Скриншот на рабочий стол",
            symbol: "camera",
            accessibility: "Скриншот",
            key: "s",
            action: #selector(takeScreenshot),
            enabled: connected,
            to: menu
        )

        // Файлы: просмотр и перетаскивание в обе стороны.
        addAction(
            "Файлы телефона…",
            symbol: "folder",
            accessibility: "Файлы",
            key: "f",
            action: #selector(showFiles),
            enabled: connected,
            to: menu
        )

        // Отправка файлов на телефон без перетаскивания: просто выбрать
        // файл в Finder и нажать «Отправить».
        addAction(
            "Отправить файл на телефон…",
            symbol: "arrow.up.doc",
            accessibility: "Отправить",
            key: "u",
            action: #selector(sendFileToPhone),
            enabled: connected,
            to: menu
        )

        menu.addItem(.separator())

        addAction(
            "Журнал зеркала…",
            symbol: "doc.text.magnifyingglass",
            accessibility: "Журнал",
            action: #selector(showMirrorLog),
            to: menu
        )

        addAction(
            "Как копировать и перетаскивать…",
            symbol: "questionmark.circle",
            accessibility: "Справка",
            action: #selector(showHelp),
            to: menu
        )

        menu.addItem(.separator())

        // 5. Выход
        addAction("Выход", key: "q", action: #selector(quit), to: menu)
    }

    /// Пункт меню с обработчиком. Иконка и горячая клавиша — по желанию.
    @discardableResult
    private func addAction(
        _ title: String,
        symbol: String? = nil,
        accessibility: String? = nil,
        key: String = "",
        action: Selector,
        enabled: Bool = true,
        to menu: NSMenu
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        if let symbol {
            item.image = NSImage(
                systemSymbolName: symbol,
                accessibilityDescription: accessibility ?? title
            )
        }
        menu.addItem(item)
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
            .sink { [weak self] _ in
                self?.rebuildMenu()
                self?.updateStatusIcon()
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
        let symbol = connected ? "iphone.gen3" : "iphone.slash"

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

    /// Отправляет выбранные в Finder файлы в Download на телефоне.
    @objc private func sendFileToPhone() {
        guard let serial = controller.readyDevice?.serial else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Отправить"
        panel.message = "Файлы будут загружены в папку Download на телефоне"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failures: [String] = []
            var sent = 0

            for url in urls {
                do {
                    try AdbFileService.push(
                        local: url,
                        to: AdbFileService.defaultUploadDirectory,
                        serial: serial
                    )
                    sent += 1
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }

            DispatchQueue.main.async {
                guard let self else { return }
                if failures.isEmpty {
                    self.post(title: "Отправлено на телефон", body: "\(sent) → Download")
                } else {
                    self.post(
                        title: "Не всё отправлено",
                        body: failures.joined(separator: "; ")
                    )
                }
            }
        }
    }

    @objc private func showMirrorLog() {
        MirrorLog.prepare()
        NSWorkspace.shared.open(MirrorLog.fileURL)
    }

    @objc private func showHelp() {
        let alert = NSAlert()
        alert.messageText = "Как копировать и перетаскивать"
        alert.informativeText = """
        Буфер обмена
        • Mac → телефон: скопируй текст на Mac (⌘C), кликни в поле на экране телефона и нажми ⌘V в окне зеркала.
        • Телефон → Mac: выдели и скопируй текст на телефоне — он сразу окажется в буфере Mac.

        Файлы
        • Mac → телефон: перетащи файл на окно зеркала или в окно «Файлы телефона» (⌘F). Ещё можно выбрать «Отправить файл на телефон…».
        • Телефон → Mac: открой «Файлы телефона» (⌘F) и перетащи файл оттуда в Finder. Перетаскивание прямо из окна зеркала не поддерживается движком scrcpy.
        """
        alert.addButton(withTitle: "Понятно")
        alert.runModal()
    }

    private func post(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

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

    /// Приложение обязано завершиться, даже если система просит подождать.
    /// Без этого при выходе через Dock остаётся висеть scrcpy.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        controller.shutdown()
        return .terminateNow
    }

    /// Клик по иконке в Dock: у приложения нет своего окна, поэтому
    /// открываем файлы телефона — иначе клик выглядит как «ничего не произошло».
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if controller.readyDevice != nil {
            DeviceFilesWindowController.present(serial: controller.readyDevice?.serial)
        } else {
            NoDeviceWindowController.present()
        }
        return true
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        // Обновляем батарею при открытии меню: цифра должна быть свежей.
        controller.refresh(forceDetails: true)
    }
}

// MARK: - Уведомления

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Показываем баннер даже когда приложение активно: иначе скриншот
    /// сохраняется «молча» и непонятно, сработало ли.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
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