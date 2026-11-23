import AppKit
import HermesKit
import UniformTypeIdentifiers

@objc(HermesDocument)
final class Document: NSDocument {
    static let hermesType = UTType(exportedAs: "dev.hermes.hrms")
    static let markdownType = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)

    private enum MarkdownContent {
        case formatted(original: Data, model: DocumentModel)
        case source(original: Data, text: String)
    }

    private(set) var model = DocumentModel()
    private var markdown: MarkdownContent?
    weak var editor: EditorViewController?

    var markdownSource: String? {
        if case .source(_, let text) = markdown { return text }
        return nil
    }

    var isMarkdown: Bool { markdown != nil }

    override init() {
        super.init()
        Exporter.configureForPaper(printInfo)
    }

    override class var autosavesInPlace: Bool { true }

    private let snapshotLock = NSLock()
    private var pendingAsyncSnapshot: (typeName: String, snapshot: SaveSnapshot)?

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        let captured = captureSaveSnapshot(ofType: typeName)
        snapshotLock.lock()
        pendingAsyncSnapshot = (typeName, captured)
        snapshotLock.unlock()
        super.save(to: url, ofType: typeName, for: saveOperation) { [weak self] error in
            self?.snapshotLock.lock()
            self?.pendingAsyncSnapshot = nil
            self?.snapshotLock.unlock()
            completionHandler(error)
        }
    }

    override func canAsynchronouslyWrite(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType
    ) -> Bool {
        snapshotLock.lock()
        let ready = pendingAsyncSnapshot?.typeName == typeName
        snapshotLock.unlock()
        return ready
    }

    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] {
        [isMarkdown ? Self.markdownType.identifier : Self.hermesType.identifier]
    }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        for controller in windowControllers {
            controller.window?.isDocumentEdited = isDocumentEdited
        }
    }

    func currentModel() -> DocumentModel {
        editor?.snapshot() ?? model
    }

    // The square window has no system title bar in which AppKit can host its rename UI.
    override func rename(_ sender: Any?) {
        guard let window = windowForSheet, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Document"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = fileURL?.deletingPathExtension().lastPathComponent ?? displayName
        field.placeholderString = "Document name"
        field.setAccessibilityLabel("Document name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.rename(to: field.stringValue) { [weak self] error in
                if let error { self?.presentError(error) }
            }
        }
        field.selectText(nil)
    }

    func rename(to proposedName: String, completionHandler: @escaping (Error?) -> Void) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains(":"), !name.contains("\0") else {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteInvalidFileNameError,
                                      userInfo: [NSLocalizedDescriptionKey: "Enter a document name without / or :."]))
            return
        }
        guard let currentURL = fileURL else {
            displayName = name
            synchronizeTitles()
            completionHandler(nil)
            return
        }
        let ext = currentURL.pathExtension
        let filename = ext.isEmpty || name.hasSuffix("." + ext) ? name : name + "." + ext
        let destination = currentURL.deletingLastPathComponent().appendingPathComponent(filename)
        if destination == currentURL { completionHandler(nil); return }
        if FileManager.default.fileExists(atPath: destination.path) {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteFileExistsError,
                                      userInfo: [NSLocalizedDescriptionKey: "A document with that name already exists. Choose another name."]))
            return
        }
        move(to: destination) { [weak self] error in
            if error == nil { self?.synchronizeTitles() }
            completionHandler(error)
        }
    }

    private func synchronizeTitles() {
        for controller in windowControllers { controller.synchronizeWindowTitleWithDocumentName() }
    }

    private enum SaveSnapshot {
        case hermes(DocumentModel)
        case markdownFormatted(original: Data, imported: DocumentModel, current: DocumentModel)
        case markdownSource(original: Data, imported: String, current: String)
        case markdownFromHermes(DocumentModel)
    }

    private func captureSaveSnapshot(ofType typeName: String) -> SaveSnapshot {
        if typeName == Self.markdownType.identifier {
            switch markdown {
            case .formatted(let original, let imported):
                return .markdownFormatted(original: original, imported: imported, current: currentModel())
            case .source(let original, let imported):
                return .markdownSource(original: original, imported: imported, current: editor?.textView.string ?? imported)
            case nil:
                return .markdownFromHermes(currentModel())
            }
        }
        if editor == nil, let source = markdownSource {
            let content = PasteNormalizer.string(fromPlain: source, style: .body, list: nil)
            return .hermes(Converter.model(from: content, appearance: .mono))
        }
        return .hermes(currentModel())
    }

    private static func encodeSnapshot(_ snapshot: SaveSnapshot) throws -> Data {
        switch snapshot {
        case .hermes(let model):
            return try HermesCore.encodeFile(model)
        case .markdownFormatted(let original, let imported, let current):
            return current == imported ? original : try HermesCore.encodeMarkdown(current)
        case .markdownSource(let original, let imported, let current):
            if current.utf8.elementsEqual(imported.utf8) { return original }
            let bom = original.starts(with: [0xEF, 0xBB, 0xBF]) ? "\u{FEFF}" : ""
            return Data((bom + current).utf8)
        case .markdownFromHermes(let model):
            return try HermesCore.encodeMarkdown(model)
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        snapshotLock.lock()
        let pending = pendingAsyncSnapshot?.typeName == typeName ? pendingAsyncSnapshot?.snapshot : nil
        if pending != nil { pendingAsyncSnapshot = nil }
        snapshotLock.unlock()

        let snapshot: SaveSnapshot
        if let pending {
            if !Thread.isMainThread { unblockUserInteraction() }
            snapshot = pending
        } else {
            snapshot = captureSaveSnapshot(ofType: typeName)
        }
        do {
            return try Self.encodeSnapshot(snapshot)
        } catch {
            throw Self.failure(error, code: NSFileWriteUnknownError)
        }
    }

    private func hermesData() throws -> Data {
        try Self.encodeSnapshot(captureSaveSnapshot(ofType: Self.hermesType.identifier))
    }

    override func read(from data: Data, ofType typeName: String) throws {
        do {
            if typeName == Self.markdownType.identifier {
                if let parsed = try HermesCore.decodeMarkdown(data) {
                    model = parsed
                    markdown = .formatted(original: data, model: parsed)
                } else {
                    var source = String(decoding: data, as: UTF8.self)
                    if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
                    model = DocumentModel()
                    markdown = .source(original: data, text: source)
                }
            } else {
                model = try HermesCore.decodeFile(data)
                markdown = nil
            }
        } catch {
            throw Self.failure(error, code: NSFileReadCorruptFileError)
        }
        editor?.loadDocument(self)
    }

    private func markdownData() throws -> Data {
        try Self.encodeSnapshot(captureSaveSnapshot(ofType: Self.markdownType.identifier))
    }

    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        Exporter.configureForPaper(info)
        return NSPrintOperation(view: Exporter.printView(for: currentModel(), printInfo: info), printInfo: info)
    }

    // MARK: Export

    @objc func exportPDF(_ sender: Any?) {
        export(as: .pdf) { [self] url in
            try Exporter.writePDF(for: currentModel(), printInfo: printInfo, to: url)
        }
    }

    @objc func exportRichText(_ sender: Any?) {
        export(as: .rtf) { [self] url in
            try Exporter.rtfData(for: currentModel()).write(to: url, options: .atomic)
        }
    }

    @objc func exportPlainText(_ sender: Any?) {
        export(as: .plainText) { [self] url in
            try Exporter.plainTextData(for: currentModel()).write(to: url, options: .atomic)
        }
    }

    @objc func exportMarkdown(_ sender: Any?) {
        export(as: Self.markdownType) { [self] url in
            try markdownData().write(to: url, options: .atomic)
        }
    }

    @objc func exportHermes(_ sender: Any?) {
        export(as: Self.hermesType) { [self] url in
            try hermesData().write(to: url, options: .atomic)
        }
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(exportHermes(_:)) { return isMarkdown }
        return super.validateUserInterfaceItem(item)
    }

    private func export(as type: UTType, write: @escaping (URL) throws -> Void) {
        guard let window = windowForSheet else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.canSelectHiddenExtension = true
        panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try write(url)
            } catch {
                self?.presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil)
            }
        }
    }

    private static func failure(_ error: Error, code: Int) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: code, userInfo: [
            NSLocalizedFailureReasonErrorKey: error.localizedDescription,
            NSUnderlyingErrorKey: error,
        ])
    }
}
