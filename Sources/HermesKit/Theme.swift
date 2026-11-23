import AppKit

/// Maps paragraph styles to typography for one document appearance.
public final class Theme {
    public static let listIndent: CGFloat = 30
    public static let quoteIndent: CGFloat = 20

    public let appearance: Appearance
    private var fonts: [FontKey: NSFont] = [:]
    private var paragraphs: [ParagraphKey: NSParagraphStyle] = [:]

    public init(appearance: Appearance) {
        self.appearance = appearance
    }

    public func font(_ style: ParagraphStyle, bold: Bool = false, italic: Bool = false, code: Bool = false, size: Int? = nil) -> NSFont {
        let key = FontKey(style: style, bold: bold, italic: italic, code: code, size: size)
        if let cached = fonts[key] { return cached }
        let spec = Self.spec(style)
        let scale: CGFloat = (appearance == .mono || code) ? 0.9 : 1
        let weight = bold ? spec.weight.strengthened : spec.weight
        let pointSize = size.map { CGFloat(min(144, max(8, $0))) } ?? (spec.size * scale).rounded()
        let font = makeFont(size: pointSize, weight: weight, italic: spec.italic != italic, monospaced: code)
        fonts[key] = font
        return font
    }

    public func paragraphStyle(_ style: ParagraphStyle, list: ListKind?, alignment: TextAlignment = .left, lineHeight: Double? = nil) -> NSParagraphStyle {
        let key = ParagraphKey(style: style, list: list, alignment: alignment, lineHeight: lineHeight)
        if let cached = paragraphs[key] { return cached }
        let p = NSMutableParagraphStyle()
        p.alignment = switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        }
        switch style {
        case .title:
            p.lineHeightMultiple = 1.1
            p.paragraphSpacing = 6
        case .subtitle:
            p.lineHeightMultiple = 1.2
            p.paragraphSpacing = 24
        case .heading:
            p.lineHeightMultiple = 1.15
            p.paragraphSpacingBefore = 24
            p.paragraphSpacing = 6
        case .subheading:
            p.lineHeightMultiple = 1.2
            p.paragraphSpacingBefore = 18
            p.paragraphSpacing = 4
        case .body, .quote:
            p.lineHeightMultiple = appearance == .mono ? 1.35 : 1.4
            p.paragraphSpacing = list == nil ? 8 : 4
            if style == .quote { p.paragraphSpacingBefore = 8 }
        }
        if let lineHeight, lineHeight.isFinite {
            p.lineHeightMultiple = CGFloat(min(3, max(1, lineHeight)))
        }
        var indent: CGFloat = 0
        if style == .quote {
            indent += Self.quoteIndent
        }
        if list != nil { indent += Self.listIndent }
        p.firstLineHeadIndent = indent
        p.headIndent = indent
        paragraphs[key] = p
        return p
    }

    /// Editor colors adapt to light and dark; export colors are fixed for paper.
    public func textColor(_ style: ParagraphStyle, forExport: Bool = false) -> NSColor {
        let muted = style == .subtitle
        if forExport {
            return muted ? NSColor(white: 0.38, alpha: 1) : .black
        }
        return muted ? .secondaryLabelColor : .textColor
    }

    public func codeBackgroundColor(forExport: Bool = false) -> NSColor {
        forExport ? NSColor(white: 0.93, alpha: 1) : .quaternaryLabelColor
    }

    private static func spec(_ style: ParagraphStyle) -> (size: CGFloat, weight: NSFont.Weight, italic: Bool) {
        switch style {
        case .title: (32, .bold, false)
        case .subtitle: (18, .regular, false)
        case .heading: (24, .semibold, false)
        case .subheading: (18, .semibold, false)
        case .body: (16, .regular, false)
        case .quote: (16, .regular, true)
        }
    }

    private static let hasCharter = NSFont(
        descriptor: NSFontDescriptor(fontAttributes: [.family: "Charter"]),
        size: 12
    )?.familyName == "Charter"

    private func makeFont(size: CGFloat, weight: NSFont.Weight, italic: Bool, monospaced: Bool = false) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight).fontDescriptor
        var descriptor: NSFontDescriptor
        if monospaced {
            descriptor = system.withDesign(.monospaced) ?? system
        } else {
            switch appearance {
            case .sans:
                descriptor = system
            case .serif:
                descriptor = system.withDesign(.serif) ?? system
            case .mono:
                descriptor = system.withDesign(.monospaced) ?? system
            case .classic where Self.hasCharter:
                descriptor = NSFontDescriptor(fontAttributes: [
                    .family: "Charter",
                    .traits: [NSFontDescriptor.TraitKey.weight: weight.rawValue],
                ])
            case .classic:
                descriptor = system.withDesign(.serif) ?? system
            }
        }
        if italic {
            descriptor = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(.italic))
        }
        return NSFont(descriptor: descriptor, size: size) ?? NSFont.systemFont(ofSize: size, weight: weight)
    }

    private struct FontKey: Hashable {
        let style: ParagraphStyle
        let bold: Bool
        let italic: Bool
        let code: Bool
        let size: Int?
    }

    private struct ParagraphKey: Hashable {
        let style: ParagraphStyle
        let list: ListKind?
        let alignment: TextAlignment
        let lineHeight: Double?
    }
}

private extension NSFont.Weight {
    var strengthened: NSFont.Weight {
        switch self {
        case ..<NSFont.Weight.medium: .bold
        case ..<NSFont.Weight.bold: .heavy
        default: .black
        }
    }
}
