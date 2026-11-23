import AppKit

/// A borderless AppKit window gives the outer frame genuinely square corners.
/// Key/main eligibility preserves document shortcuts and the normal responder chain.
final class EditorWindow: NSWindow {
    weak var header: WindowHeaderView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var title: String { didSet { updateHeader() } }
    override var subtitle: String { didSet { updateHeader() } }
    override var isDocumentEdited: Bool { didSet { updateHeader() } }

    override func standardWindowButton(_ button: NSWindow.ButtonType) -> NSButton? {
        header?.windowButtons[button] ?? super.standardWindowButton(button)
    }

    // NSWindow's performClose normally clicks its standard button. Our button uses
    // this public action too, so handle document approval directly rather than recursing.
    override func performClose(_ sender: Any?) {
        guard let document = windowController?.document else { close(); return }
        document.canClose(withDelegate: self, shouldClose: #selector(document(_:shouldClose:contextInfo:)), contextInfo: nil)
    }

    @objc private func document(_ document: NSDocument, shouldClose: Bool, contextInfo: UnsafeMutableRawPointer?) {
        if shouldClose { document.close() }
    }

    func updateHeader() {
        guard let header else { return }
        let font = header.documentTitle.font ?? .systemFont(ofSize: 12, weight: .medium)
        let label = NSMutableAttributedString(string: title, attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor,
        ])
        if isDocumentEdited {
            label.append(NSAttributedString(string: " — Edited", attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        header.documentTitle.attributedStringValue = label
        header.wordCount.stringValue = subtitle
        header.windowButtonGroup.refreshButtons()
    }
}

/// Opaque fills and a rectangular outline; no private window-frame APIs or corner masks.
final class WindowFrameView: NSView {
    static var ruleColor: NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(white: 0.25, alpha: 1)
                : NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.83, alpha: 1)
        }
    }

    override var isOpaque: Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        DocumentFileDrop.operation(for: sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        DocumentFileDrop.operation(for: sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DocumentFileDrop.operation(for: sender) == .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        DocumentFileDrop.open(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        Self.ruleColor.setStroke()
        let outline = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

enum DocumentFileDrop {
    static func containsFile(_ drag: NSDraggingInfo) -> Bool {
        drag.draggingPasteboard.availableType(from: [.fileURL]) != nil
    }

    static func operation(for drag: NSDraggingInfo) -> NSDragOperation {
        drag.draggingSourceOperationMask.contains(.copy) && !documentURLs(in: drag).isEmpty ? .copy : []
    }

    static func open(_ drag: NSDraggingInfo) -> Bool {
        guard drag.draggingSourceOperationMask.contains(.copy) else { return false }
        let urls = documentURLs(in: drag)
        let controller = NSDocumentController.shared
        for url in urls {
            controller.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error { NSApp.presentError(error) }
            }
        }
        return !urls.isEmpty
    }

    private static func documentURLs(in drag: NSDraggingInfo) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let urls = drag.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL] ?? []
        return urls.filter { url in
            switch url.pathExtension.lowercased() {
            case "md", "markdown", "hrms": !url.hasDirectoryPath
            default: false
            }
        }
    }
}

final class WindowHeaderView: NSView {
    let documentTitle = DocumentTitleLabel(labelWithString: "Untitled")
    let wordCount = HeaderLabel(labelWithString: "0 words")
    let windowButtonGroup = WindowButtonsView()
    var windowButtons: [NSWindow.ButtonType: NSButton] { windowButtonGroup.buttons }

    init(stylePopup: NSPopUpButton, formatButton: NSButton) {
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        setAccessibilityLabel("Document toolbar")
        documentTitle.font = .systemFont(ofSize: 12, weight: .medium)
        documentTitle.lineBreakMode = .byTruncatingMiddle
        documentTitle.toolTip = "Double-click to rename"
        documentTitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        wordCount.font = .systemFont(ofSize: 11)
        wordCount.textColor = .secondaryLabelColor
        wordCount.setContentHuggingPriority(.required, for: .horizontal)
        wordCount.setContentCompressionResistancePriority(.required, for: .horizontal)

        windowButtonGroup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(windowButtonGroup)
        NSLayoutConstraint.activate([
            windowButtonGroup.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            windowButtonGroup.centerYAnchor.constraint(equalTo: centerYAnchor),
            windowButtonGroup.widthAnchor.constraint(equalToConstant: 66),
            windowButtonGroup.heightAnchor.constraint(equalToConstant: 28),
        ])
        for (type, action) in [(NSWindow.ButtonType.closeButton, #selector(closeWindow)),
                               (.miniaturizeButton, #selector(minimizeWindow)),
                               (.zoomButton, #selector(fullScreen))] {
            windowButtons[type]?.target = self
            windowButtons[type]?.action = action
        }

        for child in [documentTitle, wordCount, stylePopup, formatButton] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
            child.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            documentTitle.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 96),
            documentTitle.trailingAnchor.constraint(lessThanOrEqualTo: wordCount.leadingAnchor, constant: -16),
            wordCount.trailingAnchor.constraint(equalTo: stylePopup.leadingAnchor, constant: -18),
            stylePopup.widthAnchor.constraint(equalToConstant: 116),
            stylePopup.heightAnchor.constraint(equalToConstant: 28),
            stylePopup.trailingAnchor.constraint(equalTo: formatButton.leadingAnchor, constant: -8),
            formatButton.widthAnchor.constraint(equalToConstant: 42),
            formatButton.heightAnchor.constraint(equalToConstant: 32),
            formatButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -5),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = dark ? NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.14, alpha: 1)
            : NSColor(calibratedRed: 0.965, green: 0.961, blue: 0.949, alpha: 1)
        fill.setFill()
        bounds.fill()
        WindowFrameView.ruleColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        NSRect(x: 84, y: 0, width: 1, height: bounds.height).fill()
        NSRect(x: bounds.width - 51, y: 0, width: 1, height: bounds.height).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.miniaturize(nil)
            case "None": break
            default: window.zoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    @objc private func closeWindow() { window?.performClose(nil) }
    @objc private func minimizeWindow() { window?.miniaturize(nil) }
    @objc private func fullScreen() {
        if NSApp.currentEvent?.modifierFlags.contains(.option) == true { window?.zoom(nil) }
        else { window?.toggleFullScreen(nil) }
    }
}

final class HeaderLabel: NSTextField {
    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }
}

final class DocumentTitleLabel: NSTextField {
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.windowController?.document?.rename(self)
        } else {
            superview?.mouseDown(with: event)
        }
    }
}
