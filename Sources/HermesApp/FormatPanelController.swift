import AppKit
import HermesKit

/// The compact formatting popover: text marks, lists, links, typography and app appearance.
final class FormatPanelController: NSViewController {
    private weak var editor: EditorViewController?
    private let marks = NSSegmentedControl()
    private let lists = NSSegmentedControl()
    private let alignment = NSSegmentedControl()
    private let size = NumericStepperControl(label: "Text Size in Points", range: 8...144, increment: 1, suffix: "")
    private let letterSpacing = NumericStepperControl(label: "Letter Spacing in Points", range: -5...20, increment: 0.1, suffix: " pt")
    private let lineHeight = NumericStepperControl(label: "Line Height", range: 1...3, increment: 0.1, suffix: "×")
    private let typeface = NSPopUpButton(frame: .zero, pullsDown: false)
    private let appearance = NSPopUpButton(frame: .zero, pullsDown: false)

    init(editor: EditorViewController) {
        self.editor = editor
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        configure(marks, symbols: [
            ("bold", "Bold"),
            ("italic", "Italic"),
            ("underline", "Underline"),
            ("strikethrough", "Strikethrough"),
            ("chevron.left.forwardslash.chevron.right", "Inline Code"),
        ], action: #selector(markClicked(_:)))
        configure(lists, symbols: [("list.bullet", "Bulleted List"), ("list.number", "Numbered List")], action: #selector(listClicked(_:)))
        configure(alignment, symbols: [("text.alignleft", "Align Left"), ("text.aligncenter", "Align Center"), ("text.alignright", "Align Right")], action: #selector(alignmentClicked(_:)))
        alignment.trackingMode = .selectOne
        alignment.setAccessibilityLabel("Text Alignment")

        size.onChange = { [weak self] value in
            self?.editor?.textView.setFontSize(value.map { Int($0) })
            self?.refresh()
        }
        size.toolTip = "Enter 8–144 points or use the arrows. Enter Style Default to restore the paragraph style’s value."
        letterSpacing.onChange = { [weak self] value in
            self?.editor?.textView.setLetterSpacing(value)
            self?.refresh()
        }
        letterSpacing.toolTip = "Enter −5 to 20 points or use the arrows. Zero restores normal spacing."
        lineHeight.onChange = { [weak self] value in
            self?.editor?.textView.setLineHeight(value)
            self?.refresh()
        }
        lineHeight.toolTip = "Enter 1–3× or use the arrows. Enter Style Default to restore the paragraph style’s value."

        let link = NSButton(image: NSImage(systemSymbolName: "link", accessibilityDescription: "Link")!, target: self, action: #selector(linkClicked))
        link.bezelStyle = .texturedRounded
        link.contentTintColor = .labelColor
        link.imageScaling = .scaleProportionallyDown
        link.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        link.toolTip = "Link…"

        for (index, value) in Appearance.allCases.enumerated() {
            typeface.addItem(withTitle: value.displayName)
            typeface.lastItem?.tag = index
        }
        typeface.target = self
        typeface.action = #selector(typefaceChanged(_:))
        typeface.setAccessibilityLabel("Typeface")

        for (index, value) in AppAppearance.allCases.enumerated() {
            appearance.addItem(withTitle: value.displayName)
            appearance.lastItem?.tag = index
        }
        appearance.target = AppAppearanceController.shared
        appearance.action = #selector(AppAppearanceController.changeAppearance(_:))
        appearance.setAccessibilityLabel("App Appearance")

        for control in [typeface, appearance] {
            control.controlSize = .regular
            control.font = .systemFont(ofSize: NSFont.systemFontSize)
            control.translatesAutoresizingMaskIntoConstraints = false
        }

        let row = NSStackView(views: [marks, lists, link])
        row.alignment = .centerY
        row.distribution = .fill
        row.spacing = 10

        let grid = NSGridView(views: [
            [label("Typeface"), typeface],
            [label("Size (pt)"), size],
            [label("Letter spacing"), letterSpacing],
            [label("Line height"), lineHeight],
            [label("Alignment"), alignment],
            [label("Appearance"), appearance],
        ])
        grid.columnSpacing = 12
        grid.rowSpacing = 12
        grid.rowAlignment = .none
        grid.yPlacement = .center
        grid.column(at: 0).xPlacement = .leading
        grid.column(at: 0).width = 94
        grid.column(at: 1).xPlacement = .fill

        let stack = NSStackView(views: [row, grid])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor),
            marks.widthAnchor.constraint(equalTo: lists.widthAnchor, multiplier: 2.5),
            link.widthAnchor.constraint(equalToConstant: 32),
            link.heightAnchor.constraint(equalTo: marks.heightAnchor),
        ])
        view = content
        preferredContentSize = NSSize(width: 344, height: 324)
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshIfVisible),
            name: AppAppearanceController.didChangeNotification, object: nil
        )
        for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(refreshIfVisible), name: name, object: editor?.textView)
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        refresh()
    }

    @objc private func refreshIfVisible() {
        guard isViewLoaded, view.window?.isVisible == true else { return }
        refresh()
    }

    private func configure(_ control: NSSegmentedControl, symbols: [(String, String)], action: Selector) {
        control.segmentCount = symbols.count
        control.trackingMode = .selectAny
        control.segmentStyle = .texturedRounded
        control.controlSize = .regular
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        for (index, (symbol, label)) in symbols.enumerated() {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
            control.setImage(image, forSegment: index)
            control.setToolTip(label, forSegment: index)
        }
        control.target = self
        control.action = action
    }

    private func label(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.textColor = .secondaryLabelColor
        label.font = .systemFont(ofSize: NSFont.systemFontSize)
        label.setContentHuggingPriority(.required, for: .horizontal)
        return label
    }

    @objc private func refresh() {
        guard let editor else { return }
        let usesMarkdown = editor.usesMarkdownFormatting
        marks.setEnabled(!usesMarkdown, forSegment: 2)
        typeface.isEnabled = !usesMarkdown
        alignment.isEnabled = !usesMarkdown
        size.setEnabled(!usesMarkdown)
        letterSpacing.setEnabled(!usesMarkdown)
        lineHeight.setEnabled(!usesMarkdown)
        let state = editor.textView.formattingState
        marks.setSelected(state.bold, forSegment: 0)
        marks.setSelected(state.italic, forSegment: 1)
        marks.setSelected(state.underline, forSegment: 2)
        marks.setSelected(state.strikethrough, forSegment: 3)
        marks.setSelected(state.code, forSegment: 4)
        lists.setSelected(state.list == .bullet, forSegment: 0)
        lists.setSelected(state.list == .number, forSegment: 1)
        for (index, value) in TextAlignment.allCases.enumerated() {
            alignment.setSelected(state.alignment == value, forSegment: index)
        }
        size.display(state.fontSize.map(Double.init), fallback: Double(editor.engine.theme.font(state.style).pointSize))
        letterSpacing.display(state.letterSpacing, fallback: 0)
        let defaultHeight = Double(editor.engine.theme.paragraphStyle(state.style, list: state.list).lineHeightMultiple)
        lineHeight.display(state.hasMixedLineHeight ? nil : state.effectiveLineHeight, fallback: defaultHeight)
        typeface.selectItem(at: Appearance.allCases.firstIndex(of: editor.engine.appearance) ?? 0)
        appearance.selectItem(at: AppAppearance.allCases.firstIndex(of: AppAppearanceController.shared.selection) ?? 0)
    }

    @objc private func markClicked(_ sender: NSSegmentedControl) {
        guard let textView = editor?.textView else { return }
        switch sender.selectedSegment {
        case 0: textView.toggleBold(sender)
        case 1: textView.toggleItalic(sender)
        case 2: textView.toggleUnderline(sender)
        case 3: textView.toggleStrikethrough(sender)
        default: textView.toggleCode(sender)
        }
        refresh()
    }

    @objc private func listClicked(_ sender: NSSegmentedControl) {
        guard let textView = editor?.textView else { return }
        if sender.selectedSegment == 0 { textView.toggleBulletedList(sender) } else { textView.toggleNumberedList(sender) }
        refresh()
    }

    @objc private func linkClicked() {
        guard let textView = editor?.textView else { return }
        view.window?.performClose(nil)
        textView.editLink(nil)
    }

    @objc private func typefaceChanged(_ sender: NSPopUpButton) {
        editor?.applyAppearance(sender)
    }

    @objc private func alignmentClicked(_ sender: NSSegmentedControl) {
        guard TextAlignment.allCases.indices.contains(sender.selectedSegment) else { return }
        editor?.textView.setAlignment(TextAlignment.allCases[sender.selectedSegment])
        refresh()
    }

}
