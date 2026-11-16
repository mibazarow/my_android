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

    /// Номер последнего запроса. Ответы на устаревшие запросы
    /// (пользователь уже перешёл в другую папку или сменил телефон)
    /// не должны перетирать текущий список.
    private var loadToken = UUID()

    init(serial: String?) {
        self.serial = serial
        reload()
    }

    func reload() {
        let token = UUID()
        loadToken = token

        guard let serial, !serial.isEmpty else {
            entries = []
            isLoading = false
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
                    guard let self, self.loadToken == token else { return }
                    self.entries = items
                    self.isLoading = false
                    self.statusText = "\(items.count) объектов · \(current)"
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.loadToken == token else { return }
                    self.entries = []
                    self.isLoading = false
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func open(_ entry: AdbFileService.Entry) {
        guard entry.isDirectory else { return }
        path = directoryPath(entry.path)
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
        path = directoryPath(newPath)
        reload()
    }

    /// Путь каталога всегда со слэшем на конце: adb без него не раскрывает
    /// симлинк /sdcard.
    private func directoryPath(_ path: String) -> String {
        path.hasSuffix("/") ? path : path + "/"
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
        guard let serial = serial ?? self.serial, !urls.isEmpty else { return }

        let target = directoryPath(path)
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

// MARK: - Список файлов на AppKit

/// SwiftUI `List` с `.onDrag`/`.onDrop` на macOS не даёт настоящих файловых
/// обещаний: Finder может не принять такой провайдер, а `.onDrop` поверх
/// `List` не всегда ловит перетаскивание. Поэтому список — `NSTableView`:
/// drag-out идёт через `NSFilePromiseProvider` (файл скачивается в момент
/// отпускания), drag-in — через обычный `registerForDraggedTypes`.
private struct FileListView: NSViewRepresentable {

    let entries: [AdbFileService.Entry]
    let serial: String?
    @Binding var selection: Set<String>
    let onOpen: (AdbFileService.Entry) -> Void
    let onDownload: (AdbFileService.Entry) -> Void
    let onUpload: ([URL]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = FileTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 26
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.usesAlternatingRowBackgroundColors = false
        table.selectionHighlightStyle = .regular
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .inset
        table.registerForDraggedTypes([.fileURL, .URL])
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.openRow)
        table.menu = context.coordinator.makeMenu()
        // Файловые обещания всегда копируются в место назначения.
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.setDraggingSourceOperationMask(.copy, forLocal: true)
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(entries: entries, serial: serial, selection: selection)
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSFilePromiseProviderDelegate {

        var parent: FileListView
        weak var tableView: NSTableView?

        private var entries: [AdbFileService.Entry] = []
        private var serial: String?
        private var applyingSelection = false

        init(_ parent: FileListView) {
            self.parent = parent
        }

        func update(entries: [AdbFileService.Entry], serial: String?, selection: Set<String>) {
            let changed = entries != self.entries
            self.entries = entries
            self.serial = serial

            guard let tableView else { return }

            // reloadData и восстановление выделения сами по себе присылают
            // tableViewSelectionDidChange. Пока обновляемся, не отдаём это
            // модели, иначе она решит, что пользователь снял выделение.
            applyingSelection = true

            if changed {
                tableView.reloadData()
            }

            var indexes = IndexSet()
            for (index, entry) in entries.enumerated() where selection.contains(entry.path) {
                indexes.insert(index)
            }
            if tableView.selectedRowIndexes != indexes {
                tableView.selectRowIndexes(indexes, byExtendingSelection: false)
            }

            applyingSelection = false
        }

        // MARK: Данные

        func numberOfRows(in tableView: NSTableView) -> Int {
            entries.count
        }

        func tableView(
            _ tableView: NSTableView,
            viewFor tableColumn: NSTableColumn?,
            row: Int
        ) -> NSView? {
            guard entries.indices.contains(row) else { return nil }

            let identifier = NSUserInterfaceItemIdentifier("FileCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? FileCellView)
                ?? FileCellView()
            cell.identifier = identifier
            cell.configure(entries[row])
            return cell
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let tableView else { return }

            let paths = tableView.selectedRowIndexes.compactMap { index -> String? in
                entries.indices.contains(index) ? entries[index].path : nil
            }
            let newSelection = Set(paths)
            if parent.selection != newSelection {
                parent.selection = newSelection
            }
        }

        // MARK: Двойной клик и меню

        @objc func openRow() {
            guard let tableView, tableView.clickedRow >= 0 else { return }
            open(row: tableView.clickedRow)
        }

        /// Папку открываем, файл — выделяем.
        private func open(row: Int) {
            guard entries.indices.contains(row) else { return }
            let entry = entries[row]
            if entry.isDirectory {
                parent.onOpen(entry)
            } else {
                parent.selection = [entry.path]
            }
        }

        func makeMenu() -> NSMenu {
            let menu = NSMenu()

            let open = NSMenuItem(title: "Открыть", action: #selector(openSelected), keyEquivalent: "")
            open.target = self
            menu.addItem(open)

            let download = NSMenuItem(
                title: "Скачать в Загрузки…",
                action: #selector(downloadSelected),
                keyEquivalent: ""
            )
            download.target = self
            menu.addItem(download)

            return menu
        }

        @objc private func openSelected() {
            guard let row = tableView?.clickedRow else { return }
            open(row: row)
        }

        @objc private func downloadSelected() {
            guard let row = tableView?.clickedRow, entries.indices.contains(row) else { return }
            parent.onDownload(entries[row])
        }

        // MARK: Перетаскивание наружу (файловое обещание)

        func tableView(
            _ tableView: NSTableView,
            pasteboardWriterForRow row: Int
        ) -> (any NSPasteboardWriting)? {
            guard entries.indices.contains(row) else { return nil }
            let entry = entries[row]

            let type: UTType
            if entry.isDirectory {
                type = .folder
            } else {
                type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
            }

            let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
            provider.userInfo = PromiseInfo(entry: entry, serial: serial)
            return provider
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            fileNameForType fileType: String
        ) -> String {
            (filePromiseProvider.userInfo as? PromiseInfo)?.entry.name ?? "file"
        }

        func filePromiseProvider(
            _ filePromiseProvider: NSFilePromiseProvider,
            writePromiseTo url: URL,
            completionHandler: @escaping (Error?) -> Void
        ) {
            guard let info = filePromiseProvider.userInfo as? PromiseInfo else {
                completionHandler(AdbFileService.FileError.noDevice)
                return
            }

            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try AdbFileService.pullForPromise(
                        remote: info.entry.path,
                        name: info.entry.name,
                        to: url,
                        serial: info.serial
                    )
                    completionHandler(nil)
                } catch {
                    completionHandler(error)
                }
            }
        }

        // MARK: Перетаскивание внутрь (загрузка на телефон)

        func tableView(
            _ tableView: NSTableView,
            validateDrop info: NSDraggingInfo,
            proposedRow row: Int,
            proposedDropOperation dropOperation: NSTableView.DropOperation
        ) -> NSDragOperation {
            // Внутренние перетаскивания строк нам не нужны.
            if (info.draggingSource as? NSTableView) === tableView {
                return []
            }

            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            guard info.draggingPasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: options
            ) else {
                return []
            }
            return .copy
        }

        func tableView(
            _ tableView: NSTableView,
            acceptDrop info: NSDraggingInfo,
            row: Int,
            dropOperation: NSTableView.DropOperation
        ) -> Bool {
            let options: [NSPasteboard.ReadingOptionKey: Any] = [
                .urlReadingFileURLsOnly: true
            ]
            guard let objects = info.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: options
            ) as? [NSURL], !objects.isEmpty else {
                return false
            }

            parent.onUpload(objects.map { $0 as URL })
            return true
        }

        private struct PromiseInfo {
            let entry: AdbFileService.Entry
            let serial: String?
        }
    }
}

/// `NSTableView`, который перед контекстным меню выделяет строку под курсором.
private final class FileTableView: NSTableView {
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        if row >= 0, !selectedRowIndexes.contains(row) {
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        return super.menu(for: event)
    }
}

/// Строка списка: иконка, имя, размер, дата.
private final class FileCellView: NSTableCellView {

    private let iconView = NSImageView()
    private let nameField = NSTextField(labelWithString: "")
    private let sizeField = NSTextField(labelWithString: "")
    private let dateField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) не поддерживается")
    }

    private func setup() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        sizeField.translatesAutoresizingMaskIntoConstraints = false
        dateField.translatesAutoresizingMaskIntoConstraints = false

        nameField.font = .systemFont(ofSize: 12)
        nameField.lineBreakMode = .byTruncatingMiddle
        nameField.maximumNumberOfLines = 1
        nameField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        nameField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        sizeField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        sizeField.textColor = .secondaryLabelColor
        sizeField.setContentCompressionResistancePriority(.required, for: .horizontal)
        sizeField.setContentHuggingPriority(.required, for: .horizontal)

        dateField.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        dateField.textColor = .tertiaryLabelColor
        dateField.alignment = .right
        dateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        dateField.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(iconView)
        addSubview(nameField)
        addSubview(sizeField)
        addSubview(dateField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            nameField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 9),
            nameField.centerYAnchor.constraint(equalTo: centerYAnchor),

            sizeField.leadingAnchor.constraint(
                greaterThanOrEqualTo: nameField.trailingAnchor,
                constant: 8
            ),
            sizeField.centerYAnchor.constraint(equalTo: centerYAnchor),

            dateField.leadingAnchor.constraint(equalTo: sizeField.trailingAnchor, constant: 12),
            dateField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dateField.centerYAnchor.constraint(equalTo: centerYAnchor),
            dateField.widthAnchor.constraint(equalToConstant: 100),
        ])
    }

    func configure(_ entry: AdbFileService.Entry) {
        nameField.stringValue = entry.name
        sizeField.stringValue = entry.sizeText
        dateField.stringValue = entry.modified

        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        iconView.image = NSImage(
            systemSymbolName: entry.iconName,
            accessibilityDescription: entry.name
        )?.withSymbolConfiguration(configuration)
        iconView.contentTintColor = entry.isDirectory ? .controlAccentColor : .secondaryLabelColor
    }
}

// MARK: - Экран

struct DeviceFilesView: View {

    @ObservedObject var model: DeviceFilesModel

    var body: some View {
        VStack(spacing: 0) {
            pathBar
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 520, minHeight: 380)
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
                FileListView(
                    entries: model.entries,
                    serial: model.serial,
                    selection: $model.selection,
                    onOpen: { model.open($0) },
                    onDownload: { entry in
                        model.selection = [entry.path]
                        model.downloadSelected()
                    },
                    onUpload: { urls in
                        model.upload(urls: urls, serial: model.serial)
                    }
                )
            }
        }
    }

    // MARK: Статус

    private var statusBar: some View {
        HStack(spacing: 10) {
            if model.isLoading {
                ProgressView()
                    .controlSize(.small)
            }

            Text(model.statusText.isEmpty ? "Перетащи файл из списка в Finder — он скачается сам" : model.statusText)
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
