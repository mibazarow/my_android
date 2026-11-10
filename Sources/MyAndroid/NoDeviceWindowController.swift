import AppKit
import SwiftUI

/// Окно-подсказка на случай, когда телефон не подключён.
///
/// Приложение живёт в меню-баре и не имеет своего окна, поэтому без телефона
/// вообще никак не проявляет себя: пользователь решает, что оно не запустилось.
/// Это окно появляется при старте без устройства и закрывается само,
/// как только телефон подключён.
///
/// Важно: контроллер обязан жить, пока окно на экране. Если держать его только
/// в локальной переменной, ARC освободит объект и окно исчезнет (`isVisible`
/// становится false сразу после показа). Поэтому экземпляр хранится
/// в статическом свойстве.
final class NoDeviceWindowController: NSWindowController {

    /// Живой экземпляр: держит окно, пока его не закроют.
    private static var current: NoDeviceWindowController?

    private var pollTimer: Timer?

    /// Показывает окно-подсказку. Повторный вызов переиспользует существующее.
    static func present() {
        if let existing = current, let window = existing.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = NoDeviceWindowController()
        current = controller
        controller.showAndWatch()
    }

    /// Убирает окно, если телефон подключён.
    static func dismissIfNeeded() {
        current?.dismiss()
        current = nil
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 250),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "My Android"
        window.center()
        window.isReleasedWhenClosed = false
        self.init(window: window)

        window.contentView = NSHostingView(rootView: NoDeviceView(onClose: { [weak self] in
            self?.dismiss()
        }))
    }

    /// Показывает окно и следит за подключением телефона.
    func showAndWatch() {
        guard let window else { return }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Как только телефон появился — окно убираем, зеркало поднимется само.
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            if !DeviceScanner.scan().filter({ $0.isReady }).isEmpty {
                self.dismiss()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func dismiss() {
        pollTimer?.invalidate()
        pollTimer = nil
        close()
        if NoDeviceWindowController.current === self {
            NoDeviceWindowController.current = nil
        }
    }

    deinit {
        pollTimer?.invalidate()
    }
}

private struct NoDeviceView: View {
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "iphone.gen3.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Телефон не подключён")
                .font(.system(size: 16, weight: .semibold))

            Text("Воткни кабель USB, разблокируй телефон\nи подтверди «Отладку по USB».")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Text("Зеркало появится само.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}