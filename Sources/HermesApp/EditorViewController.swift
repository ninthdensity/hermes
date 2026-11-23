import AppKit
import HermesKit

final class EditorViewController: NSViewController, NSTextViewDelegate, NSTextStorageDelegate, NSTextLayoutManagerDelegate {
    let engine = StyleEngine(appearance: .serif)
    private(set) var textView: EditorTextView!
    private weak var document: Document?
    private var isRestyling = false
    private var pendingStyleRange: NSRange?
    private var wordCountTimer: Timer?
    private let countQueue = DispatchQueue(label: "dev.hermes.wordcount", qos: .utility)

    override func loadView() {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 860, height: 720))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor

        let textView = EditorTextView(usingTextLayoutManager: true)
        textView.engine = engine
        textView.frame = NSRect(origin: .zero, size: scroll.contentSize)
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.usesFontPanel = false
        textView.usesRuler = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = true
        textView.isAutomaticDashSubstitutionEnabled = true
        textView.smartInsertDeleteEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.insertionPointColor = .controlAccentColor
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        textView.setAccessibilityLabel("Document")

        textView.delegate = self
        textView.textStorage?.delegate = self
        textView.textLayoutManager?.delegate = self
        textView.typingAttributes = engine.typingAttributes(style: .body, list: nil)

        NotificationCenter.default.addObserver(
            forName: NSTextView.willSwitchToNSLayoutManagerNotification, object: textView, queue: .main
        ) { _ in
            NSLog("Hermes: editor fell back to TextKit 1; list markers will not draw.")
        }

        scroll.documentView = textView
        self.textView = textView
        view = scroll
    }

    func attach(_ document: Document?) {
        self.document = document
        document?.editor = self
        if let document { loadDocument(document) }
    }

    func loadDocument(_ document: Document) {
        _ = view
        let source = document.markdownSource
        textView.isMarkdownSource = source != nil
        textView.isRichText = source == nil
        textView.registerForDraggedTypes(textView.acceptableDragTypes)
        textView.usesMarkdownFormatting = document.isMarkdown
        textView.isAutomaticQuoteSubstitutionEnabled = source == nil
        textView.isAutomaticDashSubstitutionEnabled = source == nil
        textView.smartInsertDeleteEnabled = source == nil
        if let source {
            pendingStyleRange = nil
            isRestyling = true
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: source,
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.textColor]
            ))
            isRestyling = false
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            updateWordCount(after: 0)
        } else {
            load(document.model)
        }
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    var usesMarkdownFormatting: Bool { document?.isMarkdown == true }

    func load(_ model: DocumentModel) {
        _ = view
        engine.appearance = model.appearance
        pendingStyleRange = nil
        isRestyling = true
        textView.textStorage?.setAttributedString(Converter.editorString(from: model, engine: engine))
        isRestyling = false
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.refreshTypingAttributes()
        updateWordCount(after: 0)
    }

    func snapshot() -> DocumentModel {
        if textView.isMarkdownSource {
            let source = PasteNormalizer.string(fromPlain: textView.string, style: .body, list: nil)
            return Converter.model(from: source, appearance: .mono)
        }
        return Converter.model(from: textView.textStorage ?? NSAttributedString(), appearance: engine.appearance)
    }

    // MARK: Appearance

    @objc func applyAppearance(_ sender: Any?) {
        let tag = (sender as? NSPopUpButton)?.selectedTag() ?? (sender as? NSMenuItem)?.tag ?? -1
        guard Appearance.allCases.indices.contains(tag) else { return }
        setAppearance(Appearance.allCases[tag])
    }

    func setAppearance(_ appearance: Appearance) {
        guard !usesMarkdownFormatting else { return }
        let previous = engine.appearance
        guard appearance != previous, let storage = textView.textStorage else { return }
        document?.undoManager?.registerUndo(withTarget: self) { $0.setAppearance(previous) }
        document?.undoManager?.setActionName("Change Appearance")
        engine.appearance = appearance
        isRestyling = true
        engine.restyleAll(storage)
        isRestyling = false
        textView.refreshTypingAttributes()
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: textView)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(applyAppearance(_:)) {
            guard !usesMarkdownFormatting else { return false }
            item.state = Appearance.allCases.firstIndex(of: engine.appearance) == item.tag ? .on : .off
        }
        return true
    }

    // MARK: Text storage

    /// Record the changed range without expanding AppKit's character-edit transaction.
    /// Styling a whole paragraph here makes TextKit move the caret to that paragraph's end.
    func textStorage(
        _ textStorage: NSTextStorage,
        willProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard !isRestyling, !textView.isMarkdownSource, editedRange.location != NSNotFound else { return }
        pendingStyleRange = pendingStyleRange.map { NSUnionRange($0, editedRange) } ?? editedRange
    }

    func textDidChange(_ notification: Notification) {
        // NSTextView has finished inserting characters and positioning its caret. Apply the
        // derived attributes in their own transaction so they only invalidate presentation.
        if let range = pendingStyleRange, let storage = textView.textStorage {
            pendingStyleRange = nil
            isRestyling = true
            engine.restyle(storage, range: range)
            isRestyling = false
        }
        updateWordCount(after: 0.3)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        textView.refreshTypingAttributes()
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return false }
        NSWorkspace.shared.open(url)
        return true
    }

    // MARK: Layout

    func textLayoutManager(
        _ textLayoutManager: NSTextLayoutManager,
        textLayoutFragmentFor location: NSTextLocation,
        in textElement: NSTextElement
    ) -> NSTextLayoutFragment {
        if let paragraph = textElement as? NSTextParagraph,
           paragraph.attributedString.length > 0,
           let list = paragraph.attributedString.listValue(at: 0) {
            return ListItemLayoutFragment(paragraph: paragraph, list: list)
        }
        return NSTextLayoutFragment(textElement: textElement, range: textElement.elementRange)
    }

    // MARK: Word count

    private var wordCountGeneration: UInt64 = 0

    deinit {
        wordCountTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    private func updateWordCount(after delay: TimeInterval) {
        wordCountTimer?.invalidate()
        wordCountGeneration &+= 1
        let generation = wordCountGeneration
        wordCountTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.wordCountGeneration == generation else { return }
            let text = self.textView.string
            self.countQueue.async {
                let count = HermesCore.wordCount(text)
                DispatchQueue.main.async {
                    guard self.wordCountGeneration == generation else { return }
                    self.view.window?.subtitle = Self.format(words: count)
                }
            }
        }
    }

    private static let numberFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static func format(words: Int) -> String {
        let n = numberFormatter.string(from: NSNumber(value: words)) ?? "\(words)"
        return words == 1 ? "1 word" : "\(n) words"
    }
}
