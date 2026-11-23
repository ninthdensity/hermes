import AppKit

/// Pure matching engine for live Markdown typing triggers.
/// All returned ranges are UTF-16 offsets relative to the start of the current paragraph.
public enum SmartMarkdown {
    public enum BlockAction: Equatable, Sendable {
        case style(ParagraphStyle)
        case list(ListKind)
    }

    public enum InlineMark: Equatable, Sendable {
        case bold
        case italic
        case strikethrough
        case code

        public var attributeKey: NSAttributedString.Key {
            switch self {
            case .bold: .hermesBold
            case .italic: .hermesItalic
            case .strikethrough: .hermesStrikethrough
            case .code: .hermesCode
            }
        }

        public var actionName: String {
            switch self {
            case .bold: "Bold"
            case .italic: "Italic"
            case .strikethrough: "Strikethrough"
            case .code: "Inline Code"
            }
        }
    }

    public enum Match: Equatable, Sendable {
        /// Delete `0..<prefixLength` (UTF-16) at the start of the paragraph and apply `action`.
        case block(prefixLength: Int, action: BlockAction)
        /// Replace `fullRange` (UTF-16) with the attributed substring at `contentRange` plus `mark`.
        case inline(fullRange: NSRange, contentRange: NSRange, mark: InlineMark)
    }

    /// Evaluates the paragraph text before the caret immediately after `trigger` was inserted.
    public static func match(paragraphPrefix: String, trigger: Character) -> Match? {
        switch trigger {
        case " ":
            return matchBlock(paragraphPrefix)
        case "*":
            return matchInline(paragraphPrefix, delimiter: "*", doubleMark: .bold, singleMark: .italic, requireWordBoundary: false)
        case "_":
            return matchInline(paragraphPrefix, delimiter: "_", doubleMark: .bold, singleMark: .italic, requireWordBoundary: true)
        case "~":
            return matchInline(paragraphPrefix, delimiter: "~", doubleMark: .strikethrough, singleMark: nil, requireWordBoundary: false)
        case "`":
            return matchCode(paragraphPrefix)
        default:
            return nil
        }
    }

    private static func matchBlock(_ prefix: String) -> Match? {
        switch prefix {
        case "# ": .block(prefixLength: 2, action: .style(.title))
        case "## ": .block(prefixLength: 3, action: .style(.heading))
        case "### ": .block(prefixLength: 4, action: .style(.subheading))
        case "> ": .block(prefixLength: 2, action: .style(.quote))
        case "- ", "* ": .block(prefixLength: 2, action: .list(.bullet))
        case "1. ": .block(prefixLength: 3, action: .list(.number))
        default: nil
        }
    }

    private static func matchInline(
        _ prefix: String,
        delimiter: Character,
        doubleMark: InlineMark?,
        singleMark: InlineMark?,
        requireWordBoundary: Bool
    ) -> Match? {
        let chars = Array(prefix)
        let count = chars.count
        guard count >= 3, chars[count - 1] == delimiter else { return nil }

        // Check double delimiter first (e.g. **bold**, __bold__, ~~strike~~).
        if let doubleMark, count >= 5, chars[count - 2] == delimiter {
            let closeStart = count - 2
            guard !chars[closeStart - 1].isWhitespace, chars[closeStart - 1] != delimiter else {
                return nil
            }
            var i = closeStart - 3
            while i >= 0 {
                if chars[i] == delimiter && chars[i + 1] == delimiter {
                    if i > 0 && chars[i - 1] == delimiter { return nil }
                    if requireWordBoundary && i > 0 && isAlphanumeric(chars[i - 1]) { return nil }
                    if chars[i + 2].isWhitespace || chars[i + 2] == delimiter { return nil }
                    return makeInlineMatch(chars: chars, openStart: i, contentStart: i + 2, contentEnd: closeStart, mark: doubleMark)
                }
                i -= 1
            }
            return nil
        }

        // Single delimiter (e.g. *italic*, _italic_), only when not closing a double delimiter.
        if let singleMark, chars[count - 2] != delimiter {
            let closeStart = count - 1
            guard !chars[closeStart - 1].isWhitespace else { return nil }
            var i = closeStart - 2
            while i >= 0 {
                if chars[i] == delimiter {
                    // Stop at the nearest matching delimiter so `**bold*` never triggers italic.
                    if i > 0 && chars[i - 1] == delimiter { return nil }
                    if requireWordBoundary && i > 0 && isAlphanumeric(chars[i - 1]) { return nil }
                    if chars[i + 1].isWhitespace || chars[i + 1] == delimiter { return nil }
                    return makeInlineMatch(chars: chars, openStart: i, contentStart: i + 1, contentEnd: closeStart, mark: singleMark)
                }
                i -= 1
            }
        }
        return nil
    }

    private static func matchCode(_ prefix: String) -> Match? {
        let chars = Array(prefix)
        let count = chars.count
        guard count >= 3, chars[count - 1] == "`", chars[count - 2] != "`" else { return nil }
        let closeStart = count - 1
        var i = closeStart - 2
        while i >= 0 {
            if chars[i] == "`" {
                if i > 0 && chars[i - 1] == "`" { return nil }
                return makeInlineMatch(chars: chars, openStart: i, contentStart: i + 1, contentEnd: closeStart, mark: .code)
            }
            i -= 1
        }
        return nil
    }

    private static func makeInlineMatch(
        chars: [Character],
        openStart: Int,
        contentStart: Int,
        contentEnd: Int,
        mark: InlineMark
    ) -> Match {
        var utf16 = [Int]()
        utf16.reserveCapacity(chars.count + 1)
        var offset = 0
        for ch in chars {
            utf16.append(offset)
            offset += ch.utf16.count
        }
        utf16.append(offset)
        let fullRange = NSRange(location: utf16[openStart], length: offset - utf16[openStart])
        let contentRange = NSRange(location: utf16[contentStart], length: utf16[contentEnd] - utf16[contentStart])
        return .inline(fullRange: fullRange, contentRange: contentRange, mark: mark)
    }

    private static func isAlphanumeric(_ ch: Character) -> Bool {
        ch.isLetter || ch.isNumber
    }
}
