import AppKit

public final class StyleEngine {
    public private(set) var theme: Theme

    public init(appearance: Appearance) {
        theme = Theme(appearance: appearance)
    }

    public var appearance: Appearance {
        get { theme.appearance }
        set { if newValue != theme.appearance { theme = Theme(appearance: newValue) } }
    }

    /// Re-derives presentation attributes for every paragraph touching `range`, giving each
    /// paragraph a single style taken from its first character, and renumbers affected lists.
    /// Pass `batched: false` from inside text storage processing, where nested editing is not allowed.
    public func restyle(_ s: NSMutableAttributedString, range: NSRange, batched: Bool = true) {
        let ns = s.string as NSString
        let length = ns.length
        guard length > 0 else { return }
        let start = min(range.location, length)
        let target = ns.paragraphRange(for: NSRange(location: start, length: min(range.length, length - start)))
        if batched { s.beginEditing() }
        var location = target.location
        while location < NSMaxRange(target) {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            styleParagraph(s, paragraph)
            location = NSMaxRange(paragraph)
        }
        renumberLists(s, ns, from: target)
        if batched { s.endEditing() }
    }

    public func restyleAll(_ s: NSMutableAttributedString) {
        restyle(s, range: NSRange(location: 0, length: s.length))
    }

    public func typingAttributes(
        style: ParagraphStyle,
        list: ListKind?,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        fontSize: Int? = nil,
        alignment: TextAlignment = .left,
        lineHeight: Double? = nil,
        letterSpacing: Double? = nil
    ) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .hermesStyle: style.rawValue,
            .font: theme.font(style, bold: bold, italic: italic, code: code, size: fontSize),
            .paragraphStyle: theme.paragraphStyle(style, list: list, alignment: alignment, lineHeight: lineHeight),
            .hermesAlignment: alignment.rawValue,
            .foregroundColor: theme.textColor(style),
        ]
        if let list { attrs[.hermesList] = list.rawValue }
        if let fontSize { attrs[.hermesFontSize] = fontSize }
        if let letterSpacing {
            attrs[.hermesLetterSpacing] = letterSpacing
            attrs[.kern] = letterSpacing
        }
        if let lineHeight { attrs[.hermesLineHeight] = lineHeight }
        if bold { attrs[.hermesBold] = true }
        if italic { attrs[.hermesItalic] = true }
        if underline {
            attrs[.hermesUnderline] = true
            attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if strikethrough {
            attrs[.hermesStrikethrough] = true
            attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if code {
            attrs[.hermesCode] = true
            attrs[.backgroundColor] = theme.codeBackgroundColor()
        }
        return attrs
    }

    private func styleParagraph(_ s: NSMutableAttributedString, _ paragraph: NSRange) {
        let style = s.paragraphStyleValue(at: paragraph.location)
        let list = s.listValue(at: paragraph.location)
        let alignment = s.alignmentValue(at: paragraph.location)
        let lineHeight = s.lineHeightValue(at: paragraph.location)
        let targetParagraphStyle = theme.paragraphStyle(style, list: list, alignment: alignment, lineHeight: lineHeight)
        let targetColor = theme.textColor(style)
        let targetCodeBg = theme.codeBackgroundColor()
        let targetStyleRaw = style.rawValue
        let targetAlignRaw = alignment.rawValue
        let targetListRaw = list?.rawValue

        var needsLineHeight = false
        var needsAlignment = false
        var needsStyle = false
        var needsList = false
        var needsRemoveOrdinal = false
        var needsParagraphStyle = false
        var needsColor = false
        struct RunEdit {
            let range: NSRange
            let font: NSFont?
            let letterSpacing: Double?
            let kernChanged: Bool
            let underlineEdit: Int?
            let strikeEdit: Int?
            let bgChanged: Bool
            let codeBg: NSColor?
        }
        var runEdits: [RunEdit] = []

        s.enumerateAttributes(in: paragraph) { attrs, range, _ in
            if (attrs[.hermesLineHeight] as? Double) != lineHeight { needsLineHeight = true }
            if (attrs[.hermesAlignment] as? String) != targetAlignRaw { needsAlignment = true }
            if (attrs[.hermesStyle] as? String) != targetStyleRaw { needsStyle = true }
            if (attrs[.hermesList] as? String) != targetListRaw { needsList = true }
            if list != .number && attrs[.hermesListOrdinal] != nil { needsRemoveOrdinal = true }
            if (attrs[.paragraphStyle] as? NSParagraphStyle) !== targetParagraphStyle,
               (attrs[.paragraphStyle] as? NSParagraphStyle) != targetParagraphStyle {
                needsParagraphStyle = true
            }
            if (attrs[.foregroundColor] as? NSColor) != targetColor { needsColor = true }

            let bold = attrs.flag(.hermesBold)
            let italic = attrs.flag(.hermesItalic)
            let underline = attrs.flag(.hermesUnderline)
            let strikethrough = attrs.flag(.hermesStrikethrough)
            let code = attrs.flag(.hermesCode)
            let fontSize = attrs[.hermesFontSize] as? Int
            let letterSpacing = attrs[.hermesLetterSpacing] as? Double
            let targetFont = theme.font(style, bold: bold, italic: italic, code: code, size: fontSize)
            let currentFont = attrs[.font] as? NSFont
            let fontChanged = currentFont !== targetFont && currentFont != targetFont
            let currentKern = attrs[.kern] as? Double
            let kernChanged = currentKern != letterSpacing
            let targetUnderline: Int? = underline ? NSUnderlineStyle.single.rawValue : nil
            let currentUnderline = attrs[.underlineStyle] as? Int
            let underlineChanged = currentUnderline != targetUnderline
            let targetStrike: Int? = strikethrough ? NSUnderlineStyle.single.rawValue : nil
            let currentStrike = attrs[.strikethroughStyle] as? Int
            let strikeChanged = currentStrike != targetStrike
            let targetBg: NSColor? = code ? targetCodeBg : nil
            let currentBg = attrs[.backgroundColor] as? NSColor
            let bgChanged = currentBg != targetBg
            if fontChanged || kernChanged || underlineChanged || strikeChanged || bgChanged {
                runEdits.append(RunEdit(
                    range: range,
                    font: fontChanged ? targetFont : nil,
                    letterSpacing: letterSpacing,
                    kernChanged: kernChanged,
                    underlineEdit: underlineChanged ? (targetUnderline ?? 0) : nil,
                    strikeEdit: strikeChanged ? (targetStrike ?? 0) : nil,
                    bgChanged: bgChanged,
                    codeBg: targetBg
                ))
            }
        }

        if needsLineHeight {
            if let lineHeight { s.addAttribute(.hermesLineHeight, value: lineHeight, range: paragraph) }
            else { s.removeAttribute(.hermesLineHeight, range: paragraph) }
        }
        if needsAlignment { s.addAttribute(.hermesAlignment, value: targetAlignRaw, range: paragraph) }
        if needsStyle { s.addAttribute(.hermesStyle, value: targetStyleRaw, range: paragraph) }
        if needsList {
            if let targetListRaw { s.addAttribute(.hermesList, value: targetListRaw, range: paragraph) }
            else { s.removeAttribute(.hermesList, range: paragraph) }
        }
        if needsRemoveOrdinal { s.removeAttribute(.hermesListOrdinal, range: paragraph) }
        if needsParagraphStyle { s.addAttribute(.paragraphStyle, value: targetParagraphStyle, range: paragraph) }
        if needsColor { s.addAttribute(.foregroundColor, value: targetColor, range: paragraph) }

        for edit in runEdits {
            if edit.kernChanged {
                if let letterSpacing = edit.letterSpacing { s.addAttribute(.kern, value: letterSpacing, range: edit.range) }
                else { s.removeAttribute(.kern, range: edit.range) }
            }
            if let font = edit.font { s.addAttribute(.font, value: font, range: edit.range) }
            if let underlineEdit = edit.underlineEdit {
                if underlineEdit != 0 { s.addAttribute(.underlineStyle, value: underlineEdit, range: edit.range) }
                else { s.removeAttribute(.underlineStyle, range: edit.range) }
            }
            if let strikeEdit = edit.strikeEdit {
                if strikeEdit != 0 { s.addAttribute(.strikethroughStyle, value: strikeEdit, range: edit.range) }
                else { s.removeAttribute(.strikethroughStyle, range: edit.range) }
            }
            if edit.bgChanged {
                if let codeBg = edit.codeBg { s.addAttribute(.backgroundColor, value: codeBg, range: edit.range) }
                else { s.removeAttribute(.backgroundColor, range: edit.range) }
            }
        }
    }

    /// Ordinals are stored on paragraphs so that a change to one item re-lays-out the items whose
    /// numbers change. Walks past `range` only while stored ordinals are stale.
    private func renumberLists(_ s: NSMutableAttributedString, _ ns: NSString, from range: NSRange) {
        var previous = 0
        if range.location > 0 {
            let prior = ns.paragraphRange(for: NSRange(location: range.location - 1, length: 0))
            if s.listValue(at: prior.location) == .number {
                previous = s.attribute(.hermesListOrdinal, at: prior.location, effectiveRange: nil) as? Int ?? 0
            }
        }
        var location = range.location
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            let beyond = paragraph.location >= NSMaxRange(range)
            guard s.listValue(at: paragraph.location) == .number else {
                if beyond { return }
                previous = 0
                location = NSMaxRange(paragraph)
                continue
            }
            let ordinal = previous + 1
            let stored = s.attribute(.hermesListOrdinal, at: paragraph.location, effectiveRange: nil) as? Int
            if stored == ordinal, beyond { return }
            if stored != ordinal { s.addAttribute(.hermesListOrdinal, value: ordinal, range: paragraph) }
            previous = ordinal
            location = NSMaxRange(paragraph)
        }
    }
}
