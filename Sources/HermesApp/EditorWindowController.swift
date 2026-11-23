import AppKit
import HermesKit

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private let editor = EditorViewController()
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let formatButton = NSButton()
    private lazy var formatPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = FormatPanelController(editor: editor)
        return popover
    }()

    init() {
        let window = EditorWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 720),
            styleMask: [.borderless, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.minSize = NSSize(width: 460, height: 360)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isOpaque = true
        window.backgroundColor = .textBackgroundColor
        window.hasShadow = true
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.center()
        super.init(window: window)
        shouldCascadeWindows = true
        window.delegate = self

        _ = editor.view
        configureHeaderControls()
        let header = WindowHeaderView(stylePopup: stylePopup, formatButton: formatButton)
        window.header = header
        let content = WindowFrameView(frame: NSRect(origin: .zero, size: window.frame.size))
        content.registerForDraggedTypes([.fileURL])
        let container = NSViewController()
        container.view = content
        container.addChild(editor)
        for child in [header, editor.view] {
            child.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(child)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: content.topAnchor, constant: 1),
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 1),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -1),
            header.heightAnchor.constraint(equalToConstant: 44),
            editor.view.topAnchor.constraint(equalTo: header.bottomAnchor),
            editor.view.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 1),
            editor.view.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -1),
            editor.view.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -1),
        ])
        window.contentViewController = container
        window.initialFirstResponder = editor.textView
        window.updateHeader()
        selectionChanged()

        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: NSTextView.didChangeSelectionNotification, object: editor.textView
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(selectionChanged),
            name: NSText.didChangeNotification, object: editor.textView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var document: AnyObject? {
        didSet {
            editor.attach(document as? Document)
            let center = NotificationCenter.default
            for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
                center.removeObserver(self, name: name, object: nil)
                if let manager = (document as? Document)?.undoManager {
                    center.addObserver(self, selector: #selector(selectionChanged), name: name, object: manager)
                }
            }
        }
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        window?.makeFirstResponder(editor.textView)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        window?.makeFirstResponder(editor.textView)
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        window?.makeFirstResponder(editor.textView)
    }

    @objc private func selectionChanged() {
        let isSource = editor.textView.isMarkdownSource
        let subtitleTag = ParagraphStyle.allCases.firstIndex(of: .subtitle)!
        stylePopup.menu?.item(withTag: subtitleTag)?.isHidden = editor.usesMarkdownFormatting
        stylePopup.menu?.item(withTag: -2)?.isHidden = !isSource
        stylePopup.isEnabled = !isSource
        formatButton.isEnabled = !isSource
        if isSource {
            stylePopup.menu?.item(withTag: -1)?.isHidden = true
            stylePopup.selectItem(withTag: -2)
            return
        }
        let state = editor.textView.formattingState
        stylePopup.menu?.item(withTag: -1)?.isHidden = !state.hasMixedStyles
        let tag = state.hasMixedStyles ? -1 : ParagraphStyle.allCases.firstIndex(of: state.style) ?? 0
        if stylePopup.selectedTag() != tag { stylePopup.selectItem(withTag: tag) }
    }

    @objc private func showFormatPopover(_ sender: NSButton) {
        if formatPopover.isShown { formatPopover.performClose(sender) }
        else { formatPopover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .maxY) }
    }

    private func configureHeaderControls() {
        for (index, style) in ParagraphStyle.allCases.enumerated() {
            stylePopup.addItem(withTitle: style.displayName)
            stylePopup.lastItem?.tag = index
        }
        stylePopup.addItem(withTitle: "Mixed Styles")
        stylePopup.lastItem?.tag = -1
        stylePopup.lastItem?.isEnabled = false
        stylePopup.lastItem?.isHidden = true
        stylePopup.addItem(withTitle: "Markdown Source")
        stylePopup.lastItem?.tag = -2
        stylePopup.lastItem?.isEnabled = false
        stylePopup.lastItem?.isHidden = true
        stylePopup.target = editor.textView
        stylePopup.action = #selector(EditorTextView.applyParagraphStyle(_:))
        stylePopup.controlSize = .regular
        stylePopup.font = .systemFont(ofSize: 12)
        stylePopup.isBordered = false
        stylePopup.alignment = .center
        stylePopup.setAccessibilityLabel("Paragraph Style")
        stylePopup.toolTip = "Paragraph Style"

        formatButton.isBordered = false
        formatButton.image = NSImage(systemSymbolName: "textformat", accessibilityDescription: "Format")
        formatButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        formatButton.imagePosition = .imageOnly
        formatButton.setAccessibilityLabel("Format")
        formatButton.toolTip = "Text formatting, typeface and appearance"
        formatButton.target = self
        formatButton.action = #selector(showFormatPopover(_:))
    }
}
