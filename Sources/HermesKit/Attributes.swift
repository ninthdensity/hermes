import AppKit

/// Semantic attributes are the source of truth in the editor; fonts, paragraph styles and
/// colors are derived from them by `StyleEngine`.
public extension NSAttributedString.Key {
    static let hermesStyle = NSAttributedString.Key("dev.hermes.style")
    static let hermesList = NSAttributedString.Key("dev.hermes.list")
    static let hermesListOrdinal = NSAttributedString.Key("dev.hermes.listOrdinal")
    static let hermesBold = NSAttributedString.Key("dev.hermes.bold")
    static let hermesItalic = NSAttributedString.Key("dev.hermes.italic")
    static let hermesUnderline = NSAttributedString.Key("dev.hermes.underline")
    static let hermesStrikethrough = NSAttributedString.Key("dev.hermes.strikethrough")
    static let hermesCode = NSAttributedString.Key("dev.hermes.code")
    static let hermesLetterSpacing = NSAttributedString.Key("dev.hermes.letterSpacing")
    static let hermesFontSize = NSAttributedString.Key("dev.hermes.fontSize")
    static let hermesAlignment = NSAttributedString.Key("dev.hermes.alignment")
    static let hermesLineHeight = NSAttributedString.Key("dev.hermes.lineHeight")

    static let hermesMarks: [NSAttributedString.Key] = [.hermesBold, .hermesItalic, .hermesUnderline, .hermesStrikethrough, .hermesCode]
}

public extension NSAttributedString {
    func lineHeightValue(at index: Int) -> Double? {
        guard index < length else { return nil }
        return attribute(.hermesLineHeight, at: index, effectiveRange: nil) as? Double
    }

    func alignmentValue(at index: Int) -> TextAlignment {
        guard index < length, let raw = attribute(.hermesAlignment, at: index, effectiveRange: nil) as? String else {
            return .left
        }
        return TextAlignment(rawValue: raw) ?? .left
    }

    func paragraphStyleValue(at index: Int) -> ParagraphStyle {
        guard index < length, let raw = attribute(.hermesStyle, at: index, effectiveRange: nil) as? String else {
            return .body
        }
        return ParagraphStyle(rawValue: raw) ?? .body
    }

    func listValue(at index: Int) -> ListKind? {
        guard index < length, let raw = attribute(.hermesList, at: index, effectiveRange: nil) as? String else {
            return nil
        }
        return ListKind(rawValue: raw)
    }

    func flag(_ key: NSAttributedString.Key, at index: Int) -> Bool {
        guard index < length else { return false }
        return attribute(key, at: index, effectiveRange: nil) as? Bool ?? false
    }
}

extension [NSAttributedString.Key: Any] {
    func flag(_ key: NSAttributedString.Key) -> Bool { self[key] as? Bool ?? false }
}

func linkString(_ value: Any?) -> String? {
    let string: String? = switch value {
    case let url as URL: url.absoluteString
    case let s as String: s
    default: nil
    }
    guard let string, !string.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return string
}

func linkValue(_ string: String) -> Any {
    URL(string: string) ?? string
}
