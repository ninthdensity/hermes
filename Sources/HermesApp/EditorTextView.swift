import AppKit
import HermesKit

struct FormattingState {
    var style: ParagraphStyle
    var hasMixedStyles: Bool
    var list: ListKind?
    var bold: Bool
    var italic: Bool
    var underline: Bool
    var strikethrough: Bool
    var code: Bool
    var fontSize: Int?
    var letterSpacing: Double?
    var alignment: TextAlignment?
    var lineHeight: Double?
    var effectiveLineHeight: Double?
    var hasMixedLineHeight: Bool
}

/// The writing surface. Formatting commands edit semantic attributes only; `StyleEngine`
/// derives fonts and spacing in a separate attribute update after each text edit.
final class EditorTextView: NSTextView {
    static let columnWidth: CGFloat = 680
    static let smartMarkdownDefaultsKey = "smartMarkdownTyping"

    var engine: StyleEngine!
    var isMarkdownSource = false
    var usesMarkdownFormatting = false
    var smartMarkdownEnabledOverride: Bool?

    var isSmartMarkdownEnabled: Bool {
        get {
            if let smartMarkdownEnabledOverride { return smartMarkdownEnabledOverride }
            return UserDefaults.standard.object(forKey: Self.smartMarkdownDefaultsKey) as? Bool ?? true
        }
        set {
            smartMarkdownEnabledOverride = nil
            UserDefaults.standard.set(newValue, forKey: Self.smartMarkdownDefaultsKey)
        }
    }

    private var storage: NSTextStorage { textStorage! }
    private var text: NSString { storage.string as NSString }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let horizontal = max(28, ((newSize.width - Self.columnWidth) / 2).rounded())
        if textContainerInset.width != horizontal {
            textContainerInset = NSSize(width: horizontal, height: 56)
        }
    }

    // MARK: Typing attributes

    /// Paragraph-level attributes always follow the paragraph at the insertion point, and fonts
    /// are always re-derived, whatever AppKit proposes.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { super.typingAttributes }
        set {
            if isMarkdownSource {
                super.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular), .foregroundColor: NSColor.textColor]
            } else {
                super.typingAttributes = engine.map { normalizedTypingAttributes(newValue, engine: $0) } ?? newValue
            }
        }
    }

    func refreshTypingAttributes() {
        typingAttributes = typingAttributes
    }

    private func normalizedTypingAttributes(
        _ proposed: [NSAttributedString.Key: Any],
        engine: StyleEngine
    ) -> [NSAttributedString.Key: Any] {
        var style = (proposed[.hermesStyle] as? String).flatMap(ParagraphStyle.init) ?? .body
        var list = (proposed[.hermesList] as? String).flatMap(ListKind.init)
        var alignment = (proposed[.hermesAlignment] as? String).flatMap(TextAlignment.init) ?? .left
        var lineHeight = proposed[.hermesLineHeight] as? Double
        let paragraph = insertionParagraph()
        if paragraph.length > 0 {
            style = storage.paragraphStyleValue(at: paragraph.location)
            list = storage.listValue(at: paragraph.location)
            alignment = storage.alignmentValue(at: paragraph.location)
            lineHeight = storage.lineHeightValue(at: paragraph.location)
        }
        var attrs = engine.typingAttributes(
            style: style,
            list: list,
            bold: proposed[.hermesBold] as? Bool ?? false,
            italic: proposed[.hermesItalic] as? Bool ?? false,
            underline: proposed[.hermesUnderline] as? Bool ?? false,
            strikethrough: proposed[.hermesStrikethrough] as? Bool ?? false,
            code: proposed[.hermesCode] as? Bool ?? false,
            fontSize: proposed[.hermesFontSize] as? Int,
            alignment: alignment,
            lineHeight: lineHeight,
            letterSpacing: proposed[.hermesLetterSpacing] as? Double
        )
        if let link = proposed[.link] { attrs[.link] = link }
        return attrs
    }

    private func insertionParagraph() -> NSRange {
        let location = min(selectedRange().location, text.length)
        return text.paragraphRange(for: NSRange(location: location, length: 0))
    }

    private func selectedParagraphs() -> [NSRange] {
        var seen = Set<Int>()
        var result: [NSRange] = []
        for value in selectedRanges {
            let range = value.rangeValue
            let start = min(range.location, text.length)
            let covered = text.paragraphRange(for: NSRange(location: start, length: min(range.length, text.length - start)))
            var location = covered.location
            while location < NSMaxRange(covered) {
                let paragraph = text.paragraphRange(for: NSRange(location: location, length: 0))
                if seen.insert(paragraph.location).inserted { result.append(paragraph) }
                location = NSMaxRange(paragraph)
            }
        }
        return result
    }

    private var nonEmptySelections: [NSRange] {
        selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
    }

    // MARK: State

    var formattingState: FormattingState {
        var coveredRanges: [NSRange] = []
        coveredRanges.reserveCapacity(selectedRanges.count)
        for value in selectedRanges {
            let range = value.rangeValue
            let start = min(range.location, text.length)
            let covered = text.paragraphRange(for: NSRange(location: start, length: min(range.length, text.length - start)))
            if covered.length > 0 { coveredRanges.append(covered) }
        }

        let style: ParagraphStyle
        let hasMixedStyles: Bool
        let list: ListKind?
        let alignment: TextAlignment?
        let lineHeight: Double?
        let effectiveLineHeight: Double?
        let hasMixedLineHeight: Bool

        if let firstRange = coveredRanges.first {
            let first = firstRange.location
            style = storage.paragraphStyleValue(at: first)
            list = storage.listValue(at: first)
            hasMixedStyles = !isUniformAttribute(.hermesStyle, in: coveredRanges) {
                ($0 as? String).flatMap(ParagraphStyle.init) ?? .body
            }
            let firstAlignment = storage.alignmentValue(at: first)
            let uniformAlignment = isUniformAttribute(.hermesAlignment, in: coveredRanges) {
                ($0 as? String).flatMap(TextAlignment.init) ?? .left
            }
            alignment = uniformAlignment ? firstAlignment : nil
            let firstLineHeight = storage.lineHeightValue(at: first)
            let uniformLineHeight = isUniformAttribute(.hermesLineHeight, in: coveredRanges) {
                $0 as? Double
            }
            hasMixedLineHeight = !uniformLineHeight
            lineHeight = uniformLineHeight ? firstLineHeight : nil
            let firstEffective = Double((storage.attribute(.paragraphStyle, at: first, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple ?? 1.4)
            let uniformEffective = isUniformAttribute(.paragraphStyle, in: coveredRanges) {
                Double(($0 as? NSParagraphStyle)?.lineHeightMultiple ?? 1.4)
            }
            effectiveLineHeight = uniformEffective ? firstEffective : nil
        } else {
            style = (typingAttributes[.hermesStyle] as? String).flatMap(ParagraphStyle.init) ?? .body
            hasMixedStyles = false
            list = (typingAttributes[.hermesList] as? String).flatMap(ListKind.init)
            alignment = (typingAttributes[.hermesAlignment] as? String).flatMap(TextAlignment.init) ?? .left
            lineHeight = typingAttributes[.hermesLineHeight] as? Double
            effectiveLineHeight = Double((typingAttributes[.paragraphStyle] as? NSParagraphStyle)?.lineHeightMultiple ?? 1.4)
            hasMixedLineHeight = false
        }

        let ranges = nonEmptySelections
        let fontSize: Int?
        let letterSpacing: Double?
        if ranges.isEmpty {
            fontSize = (typingAttributes[.font] as? NSFont).map { Int($0.pointSize.rounded()) }
            letterSpacing = typingAttributes[.hermesLetterSpacing] as? Double ?? 0
        } else {
            fontSize = uniformFontSize(in: ranges)
            letterSpacing = uniformLetterSpacing(in: ranges)
        }

        return FormattingState(
            style: style,
            hasMixedStyles: hasMixedStyles,
            list: list,
            bold: isMarkActive(.hermesBold, in: ranges),
            italic: isMarkActive(.hermesItalic, in: ranges),
            underline: isMarkActive(.hermesUnderline, in: ranges),
            strikethrough: isMarkActive(.hermesStrikethrough, in: ranges),
            code: isMarkActive(.hermesCode, in: ranges),
            fontSize: fontSize,
            letterSpacing: letterSpacing,
            alignment: alignment,
            lineHeight: lineHeight,
            effectiveLineHeight: effectiveLineHeight,
            hasMixedLineHeight: hasMixedLineHeight
        )
    }

    private func isUniformAttribute<T: Equatable>(
        _ key: NSAttributedString.Key,
        in ranges: [NSRange],
        extract: (Any?) -> T
    ) -> Bool {
        var expected: T?
        for range in ranges {
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                var effective = NSRange()
                let value = extract(storage.attribute(key, at: location, longestEffectiveRange: &effective, in: range))
                if let expected {
                    if value != expected { return false }
                } else {
                    expected = value
                }
                location = NSMaxRange(effective)
            }
        }
        return true
    }

    private func uniformFontSize(in ranges: [NSRange]) -> Int? {
        var found: Int?
        for range in ranges {
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                var effective = NSRange()
                if let font = storage.attribute(.font, at: location, longestEffectiveRange: &effective, in: range) as? NSFont {
                    let size = Int(font.pointSize.rounded())
                    if let found {
                        if size != found { return nil }
                    } else {
                        found = size
                    }
                }
                location = NSMaxRange(effective)
            }
        }
        return found
    }

    private func uniformLetterSpacing(in ranges: [NSRange]) -> Double? {
        var found: Double?
        for range in ranges {
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                var effective = NSRange()
                let value = storage.attribute(.hermesLetterSpacing, at: location, longestEffectiveRange: &effective, in: range) as? Double ?? 0
                if let found {
                    if value != found { return nil }
                } else {
                    found = value
                }
                location = NSMaxRange(effective)
            }
        }
        return found
    }

    private func isMarkActive(_ key: NSAttributedString.Key) -> Bool {
        isMarkActive(key, in: nonEmptySelections)
    }

    private func isMarkActive(_ key: NSAttributedString.Key, in ranges: [NSRange]) -> Bool {
        guard !ranges.isEmpty else { return typingAttributes[key] as? Bool ?? false }
        for range in ranges {
            var location = range.location
            let end = NSMaxRange(range)
            while location < end {
                var effective = NSRange()
                if (storage.attribute(key, at: location, longestEffectiveRange: &effective, in: range) as? Bool) != true {
                    return false
                }
                location = NSMaxRange(effective)
            }
        }
        return true
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let state = formattingState
        switch item.action {
        case #selector(applyParagraphStyle(_:)):
            guard ParagraphStyle.allCases.indices.contains(item.tag) else { return false }
            if usesMarkdownFormatting && ParagraphStyle.allCases[item.tag] == .subtitle { return false }
            item.state = !state.hasMixedStyles && ParagraphStyle.allCases.firstIndex(of: state.style) == item.tag ? .on : .off
        case #selector(toggleBold(_:)): item.state = state.bold ? .on : .off
        case #selector(toggleItalic(_:)): item.state = state.italic ? .on : .off
        case #selector(toggleUnderline(_:)):
            guard !usesMarkdownFormatting else { return false }
            item.state = state.underline ? .on : .off
        case #selector(toggleStrikethrough(_:)): item.state = state.strikethrough ? .on : .off
        case #selector(toggleCode(_:)): item.state = state.code ? .on : .off
        case #selector(toggleSmartMarkdown(_:)): item.state = isSmartMarkdownEnabled ? .on : .off
        case #selector(toggleBulletedList(_:)): item.state = state.list == .bullet ? .on : .off
        case #selector(toggleNumberedList(_:)): item.state = state.list == .number ? .on : .off
        case #selector(editLink(_:)): break
        case #selector(alignLeft(_:)), #selector(alignCenter(_:)), #selector(alignRight(_:)):
            guard !usesMarkdownFormatting else { return false }
            let alignment: TextAlignment = switch item.action {
            case #selector(alignLeft(_:)): .left
            case #selector(alignCenter(_:)): .center
            default: .right
            }
            item.state = state.alignment == alignment ? .on : .off
        default: return super.validateMenuItem(item)
        }
        return isEditable && !isMarkdownSource
    }

    // MARK: Commands

    @objc func applyParagraphStyle(_ sender: Any?) {
        let tag = (sender as? NSPopUpButton)?.selectedTag() ?? (sender as? NSMenuItem)?.tag ?? -1
        guard !isMarkdownSource, ParagraphStyle.allCases.indices.contains(tag) else { return }
        let style = ParagraphStyle.allCases[tag]
        if usesMarkdownFormatting && style == .subtitle { return }
        let paragraphs = selectedParagraphs()
        if !paragraphs.isEmpty {
            guard shouldChangeText(inRanges: paragraphs as [NSValue], replacementStrings: nil) else { return }
            storage.beginEditing()
            for paragraph in paragraphs {
                storage.addAttribute(.hermesStyle, value: style.rawValue, range: paragraph)
                storage.removeAttribute(.hermesFontSize, range: paragraph)
                storage.removeAttribute(.hermesLineHeight, range: paragraph)
                if usesMarkdownFormatting && style != .body {
                    storage.removeAttribute(.hermesList, range: paragraph)
                }
            }
            storage.endEditing()
            didChangeText()
            undoManager?.setActionName(style.displayName)
        }
        var attrs = typingAttributes
        attrs[.hermesStyle] = style.rawValue
        attrs[.hermesFontSize] = nil
        attrs[.hermesLineHeight] = nil
        if usesMarkdownFormatting && style != .body { attrs[.hermesList] = nil }
        typingAttributes = attrs
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    @objc func toggleBold(_ sender: Any?) { toggleMark(.hermesBold, actionName: "Bold") }
    @objc func toggleItalic(_ sender: Any?) { toggleMark(.hermesItalic, actionName: "Italic") }
    @objc func toggleUnderline(_ sender: Any?) {
        guard !usesMarkdownFormatting else { return }
        toggleMark(.hermesUnderline, actionName: "Underline")
    }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleMark(.hermesStrikethrough, actionName: "Strikethrough") }
    @objc func toggleCode(_ sender: Any?) { toggleMark(.hermesCode, actionName: "Inline Code") }
    @objc func toggleSmartMarkdown(_ sender: Any?) {
        isSmartMarkdownEnabled.toggle()
    }
    @objc func toggleBulletedList(_ sender: Any?) { toggleList(.bullet) }
    @objc func toggleNumberedList(_ sender: Any?) { toggleList(.number) }

    override func alignLeft(_ sender: Any?) { setAlignment(.left) }
    override func alignCenter(_ sender: Any?) { setAlignment(.center) }
    override func alignRight(_ sender: Any?) { setAlignment(.right) }

    func setAlignment(_ alignment: TextAlignment) {
        guard !usesMarkdownFormatting else { return }
        setParagraphAttribute(.hermesAlignment, to: alignment.rawValue, actionName: "Align \(alignment.displayName)")
    }

    func setLineHeight(_ multiple: Double?) {
        guard !usesMarkdownFormatting else { return }
        if let multiple, !multiple.isFinite || !(1...3).contains(multiple) { return }
        let state = formattingState
        guard state.hasMixedLineHeight || state.lineHeight != multiple else { return }
        setParagraphAttribute(.hermesLineHeight, to: multiple, actionName: "Change Line Height")
    }

    func setFontSize(_ size: Int?) {
        guard !usesMarkdownFormatting else { return }
        if let size, !(8...144).contains(size) { return }
        setRunAttribute(.hermesFontSize, to: size, actionName: "Change Text Size")
    }

    func setLetterSpacing(_ spacing: Double?) {
        guard !usesMarkdownFormatting else { return }
        if let spacing, !spacing.isFinite || !(-5...20).contains(spacing) { return }
        setRunAttribute(.hermesLetterSpacing, to: spacing == 0 ? nil : spacing, actionName: "Change Letter Spacing")
    }

    private func setRunAttribute<Value: Equatable>(_ key: NSAttributedString.Key, to value: Value?, actionName: String) {
        let ranges = nonEmptySelections
        let needsChange = ranges.contains { range in
            var differs = false
            storage.enumerateAttribute(key, in: range) { existing, _, stop in
                if (existing as? Value) != value { differs = true; stop.pointee = true }
            }
            return differs
        }
        if needsChange {
            guard shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
            storage.beginEditing()
            for range in ranges {
                if let value { storage.addAttribute(key, value: value, range: range) }
                else { storage.removeAttribute(key, range: range) }
            }
            storage.endEditing()
            didChangeText()
            undoManager?.setActionName(actionName)
        }
        var attrs = typingAttributes
        attrs[key] = value
        typingAttributes = attrs
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    private func toggleMark(_ key: NSAttributedString.Key, actionName: String) {
        guard !isMarkdownSource else { return }
        let ranges = nonEmptySelections
        let turnOn = !isMarkActive(key)
        guard !ranges.isEmpty else {
            var attrs = typingAttributes
            attrs[key] = turnOn ? true : nil
            typingAttributes = attrs
            NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
            return
        }
        guard shouldChangeText(inRanges: ranges as [NSValue], replacementStrings: nil) else { return }
        storage.beginEditing()
        for range in ranges {
            if turnOn {
                storage.addAttribute(key, value: true, range: range)
            } else {
                storage.removeAttribute(key, range: range)
            }
        }
        storage.endEditing()
        didChangeText()
        undoManager?.setActionName(actionName)
    }

    private func toggleList(_ kind: ListKind) {
        guard !isMarkdownSource else { return }
        let off = formattingState.list == kind
        setParagraphAttribute(.hermesList, to: off ? nil : kind.rawValue,
                              actionName: kind == .bullet ? "Bulleted List" : "Numbered List",
                              useBodyStyle: usesMarkdownFormatting && !off)
    }

    private func setParagraphAttribute(_ key: NSAttributedString.Key, to value: Any?, actionName: String, useBodyStyle: Bool = false) {
        let paragraphs = selectedParagraphs().filter { $0.length > 0 }
        if !paragraphs.isEmpty, shouldChangeText(inRanges: paragraphs as [NSValue], replacementStrings: nil) {
            storage.beginEditing()
            for paragraph in paragraphs {
                if useBodyStyle { storage.addAttribute(.hermesStyle, value: ParagraphStyle.body.rawValue, range: paragraph) }
                if let value {
                    storage.addAttribute(key, value: value, range: paragraph)
                } else {
                    storage.removeAttribute(key, range: paragraph)
                }
            }
            storage.endEditing()
            didChangeText()
            undoManager?.setActionName(actionName)
        }
        var attrs = typingAttributes
        attrs[key] = value
        if useBodyStyle { attrs[.hermesStyle] = ParagraphStyle.body.rawValue }
        typingAttributes = attrs
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    // MARK: Smart Markdown typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !isMarkdownSource, isSmartMarkdownEnabled, !hasMarkedText() else { return }
        let inserted = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard inserted.count == 1, let trigger = inserted.first else { return }
        // Fast path: 95%+ of keystrokes bail out before touching the text storage.
        guard trigger == " " || trigger == "*" || trigger == "_" || trigger == "~" || trigger == "`" else { return }
        applySmartMarkdown(for: trigger)
    }

    private func applySmartMarkdown(for trigger: Character) {
        let caret = selectedRange()
        guard caret.length == 0, caret.location > 0, caret.location <= text.length else { return }
        var start = 0, end = 0, contentsEnd = 0
        text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: caret.location - 1, length: 0))
        guard caret.location > start else { return }
        let prefix = text.substring(with: NSRange(location: start, length: caret.location - start))
        guard let match = SmartMarkdown.match(paragraphPrefix: prefix, trigger: trigger) else { return }

        switch match {
        case .block(let prefixLength, let action):
            guard !storage.flag(.hermesCode, at: start) else { return }
            switch action {
            case .style(let style):
                if storage.paragraphStyleValue(at: start) == style && storage.listValue(at: start) == nil { return }
            case .list(let list):
                if storage.listValue(at: start) == list { return }
            }
            applySmartBlock(paragraphStart: start, prefixLength: prefixLength, action: action)

        case .inline(let fullRel, let contentRel, let mark):
            let fullRange = NSRange(location: start + fullRel.location, length: fullRel.length)
            let contentRange = NSRange(location: start + contentRel.location, length: contentRel.length)
            guard NSMaxRange(fullRange) <= text.length else { return }
            if mark != .code && storage.flag(.hermesCode, at: contentRange.location) { return }
            applySmartInline(fullRange: fullRange, contentRange: contentRange, mark: mark)
        }
    }

    private func applySmartBlock(paragraphStart: Int, prefixLength: Int, action: SmartMarkdown.BlockAction) {
        let existingStyle = storage.paragraphStyleValue(at: paragraphStart)
        let existingAlignment = storage.alignmentValue(at: paragraphStart)
        let existingLineHeight = storage.lineHeightValue(at: paragraphStart)
        let removeRange = NSRange(location: paragraphStart, length: prefixLength)
        breakUndoCoalescing()
        undoManager?.beginUndoGrouping()
        guard shouldChangeText(in: removeRange, replacementString: "") else {
            undoManager?.endUndoGrouping()
            return
        }
        storage.deleteCharacters(in: removeRange)
        didChangeText()

        let paragraphAfter = paragraphStart < text.length
            ? text.paragraphRange(for: NSRange(location: paragraphStart, length: 0))
            : NSRange(location: paragraphStart, length: 0)

        let actionName: String
        switch action {
        case .style(let style):
            actionName = style.displayName
            if paragraphAfter.length > 0, shouldChangeText(in: paragraphAfter, replacementString: nil) {
                storage.beginEditing()
                storage.addAttribute(.hermesStyle, value: style.rawValue, range: paragraphAfter)
                storage.removeAttribute(.hermesFontSize, range: paragraphAfter)
                storage.removeAttribute(.hermesLineHeight, range: paragraphAfter)
                storage.removeAttribute(.hermesList, range: paragraphAfter)
                storage.endEditing()
                didChangeText()
            }
        case .list(let list):
            actionName = list == .bullet ? "Bulleted List" : "Numbered List"
            if paragraphAfter.length > 0, shouldChangeText(in: paragraphAfter, replacementString: nil) {
                storage.beginEditing()
                if usesMarkdownFormatting {
                    storage.addAttribute(.hermesStyle, value: ParagraphStyle.body.rawValue, range: paragraphAfter)
                }
                storage.addAttribute(.hermesList, value: list.rawValue, range: paragraphAfter)
                storage.endEditing()
                didChangeText()
            }
        }

        setSelectedRange(NSRange(location: paragraphStart, length: 0))
        var attrs = typingAttributes
        attrs[.hermesAlignment] = existingAlignment.rawValue
        switch action {
        case .style(let style):
            attrs[.hermesStyle] = style.rawValue
            attrs[.hermesFontSize] = nil
            attrs[.hermesLineHeight] = nil
            attrs[.hermesList] = nil
        case .list(let list):
            attrs[.hermesStyle] = (usesMarkdownFormatting ? ParagraphStyle.body : existingStyle).rawValue
            attrs[.hermesList] = list.rawValue
            attrs[.hermesLineHeight] = existingLineHeight
        }
        typingAttributes = attrs
        undoManager?.setActionName(actionName)
        undoManager?.endUndoGrouping()
        breakUndoCoalescing()
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    private func applySmartInline(fullRange: NSRange, contentRange: NSRange, mark: SmartMarkdown.InlineMark) {
        let replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: contentRange))
        replacement.addAttribute(mark.attributeKey, value: true, range: NSRange(location: 0, length: replacement.length))

        breakUndoCoalescing()
        guard shouldChangeText(in: fullRange, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: fullRange, with: replacement)
        didChangeText()
        undoManager?.setActionName(mark.actionName)
        let newCaret = fullRange.location + replacement.length
        setSelectedRange(NSRange(location: newCaret, length: 0))
        // Return typing attributes to un-marked so text typed right after the closing delimiter is normal.
        var attrs = typingAttributes
        attrs[mark.attributeKey] = nil
        typingAttributes = attrs
        breakUndoCoalescing()
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    // MARK: Return key

    override func insertNewline(_ sender: Any?) {
        if isMarkdownSource {
            super.insertNewline(sender)
            return
        }
        let selection = selectedRange()
        let paragraph = insertionParagraph()
        var start = 0, end = 0, contentsEnd = 0
        text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: paragraph.location, length: 0))
        let contentLength = paragraph.length > 0 ? contentsEnd - start : 0
        let state = formattingState

        // Return in an empty list item ends the list, as in Pages and TextEdit.
        if selection.length == 0, state.list != nil, contentLength == 0 {
            setParagraphAttribute(.hermesList, to: nil, actionName: "End List")
            return
        }

        let atEnd = NSMaxRange(selection) >= paragraph.location + contentLength
        super.insertNewline(sender)

        // Return at the end of a heading continues with that style's following style.
        guard atEnd, state.style.following != state.style else { return }
        let next = insertionParagraph()
        let clearedAttributes: [NSAttributedString.Key] = [
            .hermesFontSize, .hermesLineHeight, .hermesLetterSpacing,
            .hermesBold, .hermesItalic, .hermesUnderline, .hermesStrikethrough, .hermesCode, .link,
        ]
        if next.length > 0, shouldChangeText(in: next, replacementString: nil) {
            storage.beginEditing()
            for key in clearedAttributes { storage.removeAttribute(key, range: next) }
            storage.addAttribute(.hermesStyle, value: state.style.following.rawValue, range: next)
            storage.endEditing()
            didChangeText()
        }
        var attrs = typingAttributes
        attrs[.hermesStyle] = state.style.following.rawValue
        for key in clearedAttributes { attrs[key] = nil }
        typingAttributes = attrs
        NotificationCenter.default.post(name: NSTextView.didChangeSelectionNotification, object: self)
    }

    // MARK: Links

    @objc func editLink(_ sender: Any?) {
        guard !isMarkdownSource, let window else { return }
        let range = selectedRange()
        let existing = range.length > 0
            ? storage.attribute(.link, at: range.location, effectiveRange: nil)
            : typingAttributes[.link]
        let current = (existing as? URL)?.absoluteString ?? existing as? String

        let alert = NSAlert()
        alert.messageText = current == nil ? "Add Link" : "Edit Link"
        alert.informativeText = range.length > 0 ? "Link the selected text to:" : "Insert a link to:"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "https://example.com"
        field.stringValue = current ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if current != nil { alert.addButton(withTitle: "Remove Link") }
        alert.window.initialFirstResponder = field

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                guard let url = Self.normalizedURL(field.stringValue) else { return }
                self.applyLink(url, to: range)
            case .alertThirdButtonReturn:
                self.applyLink(nil, to: range)
            default:
                break
            }
        }
    }

    func applyLink(_ url: URL?, to range: NSRange) {
        if range.length == 0 {
            guard let url else { return }
            var attrs = typingAttributes
            attrs[.link] = url
            insertText(NSAttributedString(string: url.absoluteString, attributes: attrs), replacementRange: range)
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        if let url {
            storage.addAttribute(.link, value: url, range: range)
        } else {
            storage.removeAttribute(.link, range: range)
        }
        didChangeText()
        undoManager?.setActionName(url == nil ? "Remove Link" : "Link")
    }

    private static func normalizedURL(_ input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains("://") || trimmed.hasPrefix("mailto:") { return URL(string: trimmed) }
        if trimmed.contains("@"), !trimmed.contains("/") { return URL(string: "mailto:\(trimmed)") }
        return URL(string: "https://\(trimmed)")
    }

    // MARK: Pasteboard

    override var acceptableDragTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + super.acceptableDragTypes
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DocumentFileDrop.containsFile(sender) { return DocumentFileDrop.operation(for: sender) }
        return super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if DocumentFileDrop.containsFile(sender) { return DocumentFileDrop.operation(for: sender) }
        return super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if DocumentFileDrop.containsFile(sender) { return DocumentFileDrop.operation(for: sender) == .copy }
        return super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if DocumentFileDrop.containsFile(sender) { return DocumentFileDrop.open(sender) }
        return super.performDragOperation(sender)
    }

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        isMarkdownSource ? [.string] : [.hermesFragment] + super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .hermesFragment else { return super.writeSelection(to: pboard, type: type) }
        guard let range = nonEmptySelections.first,
              let data = PasteNormalizer.fragmentData(for: storage.attributedSubstring(from: range))
        else { return false }
        return pboard.setData(data, forType: type)
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        isMarkdownSource ? [.string] : [.hermesFragment, .legacyWritingFragment, .rtfd, .rtf, .html, .string]
    }

    /// Normalize pasted or dropped text to the editor’s formatting.
    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        if isMarkdownSource { return super.readSelection(from: pboard, type: .string) }
        let state = formattingState
        let pasted: NSAttributedString?
        switch type {
        case .hermesFragment, .legacyWritingFragment:
            pasted = pboard.data(forType: type).flatMap(PasteNormalizer.string(fromFragment:))
        case .string:
            pasted = pboard.string(forType: .string).map { plain in
                let s = NSMutableAttributedString(attributedString: PasteNormalizer.string(fromPlain: plain, style: state.style, list: state.list))
                let whole = NSRange(location: 0, length: s.length)
                if state.bold { s.addAttribute(.hermesBold, value: true, range: whole) }
                if state.italic { s.addAttribute(.hermesItalic, value: true, range: whole) }
                if state.underline { s.addAttribute(.hermesUnderline, value: true, range: whole) }
                if state.strikethrough { s.addAttribute(.hermesStrikethrough, value: true, range: whole) }
                if state.code { s.addAttribute(.hermesCode, value: true, range: whole) }
                return s
            }
        default:
            pasted = (pboard.readObjects(forClasses: [NSAttributedString.self]) as? [NSAttributedString])?.first
                .map { PasteNormalizer.string(fromForeign: $0, style: state.style, list: state.list) }
        }
        guard let pasted else { return false }
        let normalized = NSMutableAttributedString(attributedString: pasted)
        if type != .hermesFragment && type != .legacyWritingFragment {
            let whole = NSRange(location: 0, length: normalized.length)
            if let size = typingAttributes[.hermesFontSize] { normalized.addAttribute(.hermesFontSize, value: size, range: whole) }
            if let spacing = typingAttributes[.hermesLetterSpacing] { normalized.addAttribute(.hermesLetterSpacing, value: spacing, range: whole) }
            let alignment = formattingState.alignment ?? .left
            normalized.addAttribute(.hermesAlignment, value: alignment.rawValue, range: whole)
            if let lineHeight = typingAttributes[.hermesLineHeight] {
                normalized.addAttribute(.hermesLineHeight, value: lineHeight, range: whole)
            }
        }
        let range = rangeForUserTextChange
        guard range.location != NSNotFound, shouldChangeText(in: range, replacementString: pasted.string) else { return false }
        storage.replaceCharacters(in: range, with: normalized)
        didChangeText()
        setSelectedRange(NSRange(location: range.location + pasted.length, length: 0))
        scrollRangeToVisible(selectedRange())
        return true
    }
}
