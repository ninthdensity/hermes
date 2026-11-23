import AppKit

public extension NSPasteboard.PasteboardType {
    /// A model fragment, so copy and paste between Hermes documents keeps paragraph styles.
    static let hermesFragment = NSPasteboard.PasteboardType("dev.hermes.fragment")
    /// Accept styled content copied from the previous app.
    static let legacyWritingFragment = NSPasteboard.PasteboardType("dev.quire.fragment")
}

public enum PasteNormalizer {
    public static func fragmentData(for selection: NSAttributedString) -> Data? {
        try? JSONEncoder().encode(Converter.model(from: selection, appearance: .serif))
    }

    public static func string(fromFragment data: Data) -> NSAttributedString? {
        guard let model = try? JSONDecoder().decode(DocumentModel.self, from: data) else { return nil }
        return Converter.semanticString(from: model)
    }

    /// Keeps only what Hermes models from foreign rich text: bold, italic, underline, strikethrough, inline code and links.
    /// Pasted paragraphs take the destination paragraph's style, so pasting matches the document.
    public static func string(fromForeign foreign: NSAttributedString, style: ParagraphStyle, list: ListKind?) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ns = foreign.string as NSString
        // Only promote foreign monospace runs to inline code when mixed with proportional text
        // (so pasting from a terminal doesn't mark an entire pasted block as inline code).
        var hasProportional = false
        foreign.enumerateAttribute(.font, in: NSRange(location: 0, length: ns.length)) { value, _, stop in
            if let font = value as? NSFont, !font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                hasProportional = true
                stop.pointee = true
            }
        }
        foreign.enumerateAttributes(in: NSRange(location: 0, length: ns.length)) { attrs, range, _ in
            let text = clean(ns.substring(with: range))
            guard !text.isEmpty else { return }
            var marks: [NSAttributedString.Key: Any] = [:]
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) || weight(of: font) >= NSFont.Weight.semibold.rawValue { marks[.hermesBold] = true }
                if traits.contains(.italic) { marks[.hermesItalic] = true }
                if hasProportional && traits.contains(.monoSpace) { marks[.hermesCode] = true }
            }
            if let underline = attrs[.underlineStyle] as? Int, underline != 0 { marks[.hermesUnderline] = true }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { marks[.hermesStrikethrough] = true }
            if let link = linkString(attrs[.link]) { marks[.link] = linkValue(link) }
            out.append(NSAttributedString(string: text, attributes: marks))
        }
        applyParagraphAttributes(out, style: style, list: list)
        return out
    }

    public static func string(fromPlain plain: String, style: ParagraphStyle, list: ListKind?) -> NSAttributedString {
        let out = NSMutableAttributedString(string: clean(plain))
        applyParagraphAttributes(out, style: style, list: list)
        return out
    }

    private static func applyParagraphAttributes(_ s: NSMutableAttributedString, style: ParagraphStyle, list: ListKind?) {
        let ns = s.string as NSString
        var location = 0
        var current = style
        while location < ns.length {
            let paragraph = ns.paragraphRange(for: NSRange(location: location, length: 0))
            s.addAttribute(.hermesStyle, value: current.rawValue, range: paragraph)
            if let list { s.addAttribute(.hermesList, value: list.rawValue, range: paragraph) }
            current = current.following
            location = NSMaxRange(paragraph)
        }
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2029}", with: "\n")
            .replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\0", with: "")
    }

    private static func weight(of font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? CGFloat ?? 0
    }
}
