import AppKit

/// Converts between the document model and attributed strings carrying semantic attributes.
public enum Converter {
    public static func model(from s: NSAttributedString, appearance: Appearance) -> DocumentModel {
        let ns = s.string as NSString
        let hasAttachments = ns.length > 0 && ns.range(of: "\u{FFFC}").location != NSNotFound
        var blocks: [Block] = []
        var location = 0
        while location < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
            var runs: [Run] = []
            var firstAttrs: [NSAttributedString.Key: Any]?
            let content = NSRange(location: start, length: contentsEnd - start)
            if content.length > 0 {
                s.enumerateAttributes(in: content, options: .longestEffectiveRangeNotRequired) { attrs, range, _ in
                    if firstAttrs == nil { firstAttrs = attrs }
                    let raw = ns.substring(with: range)
                    let text = hasAttachments ? raw.replacingOccurrences(of: "\u{FFFC}", with: "") : raw
                    runs.append(Run(
                        text: text,
                        bold: attrs.flag(.hermesBold),
                        italic: attrs.flag(.hermesItalic),
                        underline: attrs.flag(.hermesUnderline),
                        strikethrough: attrs.flag(.hermesStrikethrough),
                        code: attrs.flag(.hermesCode),
                        link: linkString(attrs[.link]),
                        fontSize: attrs[.hermesFontSize] as? Int,
                        letterSpacing: attrs[.hermesLetterSpacing] as? Double
                    ))
                }
            }
            let pAttrs = firstAttrs ?? s.attributes(at: start, effectiveRange: nil)
            let style = (pAttrs[.hermesStyle] as? String).flatMap(ParagraphStyle.init) ?? .body
            let list = (pAttrs[.hermesList] as? String).flatMap(ListKind.init)
            let alignment = (pAttrs[.hermesAlignment] as? String).flatMap(TextAlignment.init) ?? .left
            let lineHeight = pAttrs[.hermesLineHeight] as? Double
            blocks.append(Block(style: style, list: list, alignment: alignment, lineHeight: lineHeight, runs: runs))
            location = end
        }
        if let last = blocks.last, ns.length > 0, endsWithParagraphBreak(ns) {
            blocks.append(Block(style: last.style.following, list: last.list, alignment: last.alignment, lineHeight: last.lineHeight))
        }
        return DocumentModel(appearance: appearance, blocks: blocks.isEmpty ? [Block()] : blocks)
    }

    /// Text with semantic attributes only; run it through `StyleEngine` before display.
    public static func semanticString(from model: DocumentModel) -> NSMutableAttributedString {
        let s = NSMutableAttributedString()
        s.beginEditing()
        for (index, block) in model.blocks.enumerated() {
            var paragraphAttrs: [NSAttributedString.Key: Any] = [.hermesStyle: block.style.rawValue, .hermesAlignment: block.alignment.rawValue]
            if let list = block.list { paragraphAttrs[.hermesList] = list.rawValue }
            if let lineHeight = block.lineHeight { paragraphAttrs[.hermesLineHeight] = lineHeight }
            for run in block.runs where !run.text.isEmpty {
                var attrs = paragraphAttrs
                if run.bold { attrs[.hermesBold] = true }
                if run.italic { attrs[.hermesItalic] = true }
                if run.underline { attrs[.hermesUnderline] = true }
                if run.strikethrough { attrs[.hermesStrikethrough] = true }
                if run.code { attrs[.hermesCode] = true }
                if let link = run.link { attrs[.link] = linkValue(link) }
                if let size = run.fontSize { attrs[.hermesFontSize] = size }
                if let spacing = run.letterSpacing { attrs[.hermesLetterSpacing] = spacing }
                s.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if index < model.blocks.count - 1 {
                s.append(NSAttributedString(string: "\n", attributes: paragraphAttrs))
            }
        }
        s.endEditing()
        return s
    }

    /// Single-pass construction combining semantic and derived presentation attributes so
    /// loading large documents avoids a second full-document restyle pass.
    public static func editorString(from model: DocumentModel, engine: StyleEngine) -> NSMutableAttributedString {
        let theme = engine.theme
        var defaultParagraphAttrs: [ParagraphStyle: [NSAttributedString.Key: Any]] = [:]
        defaultParagraphAttrs.reserveCapacity(ParagraphStyle.allCases.count)
        for style in ParagraphStyle.allCases {
            defaultParagraphAttrs[style] = [
                .hermesStyle: style.rawValue,
                .hermesAlignment: TextAlignment.left.rawValue,
                .paragraphStyle: theme.paragraphStyle(style, list: nil, alignment: .left, lineHeight: nil),
                .foregroundColor: theme.textColor(style),
                .font: theme.font(style),
            ]
        }

        let s = NSMutableAttributedString()
        var ordinal = 0
        s.beginEditing()
        for (index, block) in model.blocks.enumerated() {
            let paragraphAttrs: [NSAttributedString.Key: Any]
            if block.list == nil && block.alignment == .left && block.lineHeight == nil {
                ordinal = 0
                paragraphAttrs = defaultParagraphAttrs[block.style]!
            } else {
                var custom: [NSAttributedString.Key: Any] = [
                    .hermesStyle: block.style.rawValue,
                    .hermesAlignment: block.alignment.rawValue,
                    .paragraphStyle: theme.paragraphStyle(block.style, list: block.list, alignment: block.alignment, lineHeight: block.lineHeight),
                    .foregroundColor: theme.textColor(block.style),
                    .font: theme.font(block.style),
                ]
                if let list = block.list {
                    custom[.hermesList] = list.rawValue
                    if list == .number {
                        ordinal += 1
                        custom[.hermesListOrdinal] = ordinal
                    } else {
                        ordinal = 0
                    }
                } else {
                    ordinal = 0
                }
                if let lineHeight = block.lineHeight { custom[.hermesLineHeight] = lineHeight }
                paragraphAttrs = custom
            }
            for run in block.runs where !run.text.isEmpty {
                let hasRunOverrides = run.bold || run.italic || run.underline || run.strikethrough || run.code || run.link != nil || run.fontSize != nil || run.letterSpacing != nil
                if !hasRunOverrides {
                    s.append(NSAttributedString(string: run.text, attributes: paragraphAttrs))
                } else {
                    var attrs = paragraphAttrs
                    if run.bold { attrs[.hermesBold] = true }
                    if run.italic { attrs[.hermesItalic] = true }
                    if run.bold || run.italic || run.code || run.fontSize != nil {
                        attrs[.font] = theme.font(block.style, bold: run.bold, italic: run.italic, code: run.code, size: run.fontSize)
                    }
                    if run.underline {
                        attrs[.hermesUnderline] = true
                        attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if run.strikethrough {
                        attrs[.hermesStrikethrough] = true
                        attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    }
                    if run.code {
                        attrs[.hermesCode] = true
                        attrs[.backgroundColor] = theme.codeBackgroundColor()
                    }
                    if let link = run.link { attrs[.link] = linkValue(link) }
                    if let size = run.fontSize { attrs[.hermesFontSize] = size }
                    if let spacing = run.letterSpacing {
                        attrs[.hermesLetterSpacing] = spacing
                        attrs[.kern] = spacing
                    }
                    s.append(NSAttributedString(string: run.text, attributes: attrs))
                }
            }
            if index < model.blocks.count - 1 {
                s.append(NSAttributedString(string: "\n", attributes: paragraphAttrs))
            }
        }
        s.endEditing()
        return s
    }

    private static func endsWithParagraphBreak(_ ns: NSString) -> Bool {
        switch ns.character(at: ns.length - 1) {
        case 0x0A, 0x0D, 0x2029: true
        default: false
        }
    }
}
