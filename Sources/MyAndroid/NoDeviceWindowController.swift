import AppKit
import SwiftUI
import Combine

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

    /// Подписка на состояние телефона вместо отдельного таймера с adb.
    private var cancellable: AnyCancellable?

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

        window.delegate = self
        window.contentView = NSHostingView(rootView: NoDeviceView())
    }

    /// Показывает окно и следит за подключением телефона.
    func showAndWatch() {
        guard let window else { return }

        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Как только телефон появился — окно убираем, зеркало поднимется само.
        // Никакого собственного опроса adb здесь нет: он уже идёт в
        // MirrorController, и второй экземпляр только зря дёргал бы телефон.
        cancellable = MirrorController.shared.$devices
            .receive(on: RunLoop.main)
            .sink { [weak self] devices in
                if devices.contains(where: { $0.isReady }) {
                    self?.dismiss()
                }
            }
    }

    func dismiss() {
        detach()
        close()
    }

    private func detach() {
        cancellable = nil
        if NoDeviceWindowController.current === self {
            NoDeviceWindowController.current = nil
        }
    }
}

extension NoDeviceWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        detach()
    }
}

private struct NoDeviceView: View {
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
