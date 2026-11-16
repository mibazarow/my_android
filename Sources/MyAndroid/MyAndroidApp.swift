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
        files.image = NSImage(systemSymbolName: "folder", accessibilityDescription: "Файлы")
        files.isEnabled = connected
        menu.addItem(files)

        // Отправка файлов на телефон без перетаскивания: просто выбрать
        // файл в Finder и нажать «Отправить».
        let send = NSMenuItem(
            title: "Отправить файл на телефон…",
            action: #selector(sendFileToPhone),
            keyEquivalent: "u"
        )
        send.target = self
        send.image = NSImage(systemSymbolName: "arrow.up.doc", accessibilityDescription: "Отправить")
        send.isEnabled = connected
        menu.addItem(send)

        menu.addItem(.separator())

        let log = NSMenuItem(
            title: "Журнал зеркала…",
            action: #selector(showMirrorLog),
            keyEquivalent: ""
        )
        log.target = self
        log.image = NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: "Журнал")
        menu.addItem(log)

        let help = NSMenuItem(
            title: "Как копировать и перетаскивать…",
            action: #selector(showHelp),
            keyEquivalent: ""
        )
        help.target = self
        help.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: "Справка")
        menu.addItem(help)

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