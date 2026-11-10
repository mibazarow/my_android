import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Окно браузера файлов

/// Окно «Файлы телефона»: просмотр содержимого и перетаскивание в обе стороны.
final class DeviceFilesWindowController: NSWindowController {

    private static var current: DeviceFilesWindowController?

    static func present(serial: String?) {
        if let existing = current, let window = existing.window {
            existing.model.serial = serial
            existing.model.reload()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let controller = DeviceFilesWindowController(serial: serial)
        current = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private let model: DeviceFilesModel

    init(serial: String?) {
        let model = DeviceFilesModel(serial: serial)
        self.model = model

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Файлы телефона"
        window.center()
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 380)

        super.init(window: window)

        window.contentView = NSHostingView(rootView: DeviceFilesView(model: model))
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }

    deinit {
        if DeviceFilesWindowController.current === self {
            DeviceFilesWindowController.current = nil
        }
    }
}

extension DeviceFilesWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if DeviceFilesWindowController.current === self {
            DeviceFilesWindowController.current = nil
        }
    }
}

// MARK: - Модель

final class DeviceFilesModel: ObservableObject {

    @Published var serial: String?
    @Published var path: String = "/sdcard/"
    @Published var entries: [AdbFileService.Entry] = []
    @Published var isLoading = false
    @Published var errorText: String?
    @Published var statusText: String = ""
    @Published var selection: Set<String> = []

    init(serial: String?) {
        self.serial = serial
        reload()
    }

    func reload() {
        guard let serial, !serial.isEmpty else {
            entries = []
            errorText = "Телефон не подключён"
            return
        }

        isLoading = true
        errorText = nil

        let current = path
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let items = try AdbFileService.list(path: current, serial: serial)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.entries = items
                    self.isLoading = false
                    self.statusText = "\(items.count) объектов · \(current)"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.entries = []
                    self.isLoading = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func open(_ entry: AdbFileService.Entry) {
        guard entry.isDirectory else { return }
        path = entry.path.hasSuffix("/") ? entry.path : entry.path + "/"
        selection.removeAll()
        reload()
    }

    func goUp() {
        guard path != "/" else { return }
        var trimmed = path
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        if let index = trimmed.lastIndex(of: "/") {
            let parent = String(trimmed[..<index])
            path = parent.isEmpty ? "/" : parent + "/"
        } else {
            path = "/"
        }
        reload()
    }

    func go(to newPath: String) {
        path = newPath.hasSuffix("/") ? newPath : newPath + "/"
        reload()
    }

    /// Скачивает выбранные объекты в папку, выбранную пользователем.
    func downloadSelected() {
        let chosen = entries.filter { selection.contains($0.path) }
        guard !chosen.isEmpty else {
            statusText = "Ничего не выбрано"
            return
        }
        guard let serial else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Скачать сюда"
        panel.message = "Куда сохранить \(chosen.count) объект(ов)"
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        statusText = "Скачиваю…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [String] = []
            for entry in chosen {
                let target = destination.appendingPathComponent(entry.name)
                do {
                    try AdbFileService.pull(remote: entry.path, to: target, serial: serial)
                } catch {
                    failed.append("\(entry.name): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if failed.isEmpty {
                    self.statusText = "Скачано: \(chosen.count) → \(destination.lastPathComponent)"
                } else {
                    self.statusText = "Ошибки: \(failed.joined(separator: "; "))"
                }
            }
        }
    }

    /// Загружает файлы с мака в текущий каталог телефона.
    func upload() {
        guard let serial else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Загрузить"
        panel.message = "Что загрузить в \(path)"

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        upload(urls: panel.urls, serial: serial)
    }

    /// Загрузка конкретных URL (в том числе из перетаскивания).
    func upload(urls: [URL], serial: String?) {
        guard let serial, !urls.isEmpty else { return }

        let target = path.hasSuffix("/") ? path : path + "/"
        statusText = "Загружаю \(urls.count) объект(ов)…"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var failed: [String] = []
            for url in urls {
                do {
                    try AdbFileService.push(local: url, to: target, serial: serial)
                } catch {
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                if failed.isEmpty {
                    self.statusText = "Загружено: \(urls.count) → \(target)"
                } else {
                    self.statusText = "Ошибки: \(failed.joined(separator: "; "))"
                }
                self.reload()
            }
        }
    }
}

// MARK: - Провайдер для перетаскивания

/// Готовит NSItemProvider для перетаскивания файла из телефона наружу.
/// Файл скачивается лениво: только когда пользователь отпустил его в Finder.
enum DragProvider {

    static func make(for entry: AdbFileService.Entry, serial: String?) -> NSItemProvider {
        let provider = NSItemProvider()

        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        let remote = entry.path
        let name = entry.name

        provider.suggestedName = name
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [],
            visibility: .all
        ) { completion in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let url = try AdbFileService.pullToTemporary(
                        remote: remote,
                        name: name,
                        serial: serial
                    )
                    completion(url, false, nil)
                } catch {
                    completion(nil, false, error)
                }
            }
            return nil
        }

        return provider
    }
}

struct DeviceFilesView: View {

    @ObservedObject var model: DeviceFilesModel
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 520, minHeight: 380)
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
        }
    }

    // MARK: Путь

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .help("На уровень выше")
            .disabled(model.path == "/")

            Menu {
                ForEach(AdbFileService.roots, id: \.path) { root in
                    Button(root.title) { model.go(to: root.path) }
                }
            } label: {
                Image(systemName: "house")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help("Быстрый переход")

            Text(model.path)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Обновить")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Список

    private var content: some View {
        Group {
            if let error = model.errorText {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(error)
                        .font(.system(size: 12))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.isLoading && model.entries.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.entries.isEmpty {
                Text("Пусто")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selection) {
                    ForEach(model.entries) { entry in
                        row(for: entry)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private func row(for entry: AdbFileService.Entry) -> some View {
        HStack(spacing: 9) {
            Image(systemName: entry.iconName)
                .foregroundStyle(entry.isDirectory ? Color.accentColor : Color.secondary)
                .frame(width: 18)

            Text(entry.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(entry.sizeText)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .monospacedDigit()

            Text(entry.modified)
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
                .frame(width: 100, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if entry.isDirectory {
                model.open(entry)
            } else {
                model.selection = [entry.path]
            }
        }
        // Перетаскивание наружу: файл скачается, когда его отпустят в Finder.
        .onDrag {
            DragProvider.make(for: entry, serial: model.serial)
        }
        .contextMenu {
            if entry.isDirectory {
                Button("Открыть") { model.open(entry) }
            }
            Button("Скачать в Загрузки…") {
                model.selection = [entry.path]
                model.downloadSelected()
            }
        }
    }

    // MARK: Загрузка перетаскиванием

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false

        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
                continue
            }
            accepted = true

            // loadItem устарел в macOS 27 — используем loadObject(ofClass:).
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let fileURL = url else { return }
                DispatchQueue.main.async {
                    model.upload(urls: [fileURL], serial: model.serial)
                }
            }
        }

        return accepted
    }

    // MARK: Статус

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Text(model.statusText.isEmpty ? "Перетащи файл наружу — он скачается сам" : model.statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button("Загрузить…") {
                model.upload()
            }
            .controlSize(.small)
            .help("Загрузить файлы с мака в текущую папку")

            Button("Скачать…") {
                model.downloadSelected()
            }
            .controlSize(.small)
            .disabled(model.selection.isEmpty)
            .help("Скачать выбранное на мак")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}