import Foundation

public enum ParagraphStyle: String, Codable, CaseIterable, Sendable {
    case title, subtitle, heading, subheading, body, quote

    public var displayName: String {
        switch self {
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .heading: "Heading"
        case .subheading: "Subheading"
        case .body: "Body"
        case .quote: "Quote"
        }
    }

    /// The style a new paragraph takes after pressing Return at the end of this one.
    public var following: ParagraphStyle {
        switch self {
        case .title, .subtitle, .heading, .subheading: .body
        case .body, .quote: self
        }
    }
}

public enum ListKind: String, Codable, Sendable {
    case bullet, number
}

public enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left, center, right

    public var displayName: String { rawValue.capitalized }
}

public enum Appearance: String, Codable, CaseIterable, Sendable {
    case serif, sans, classic, mono

    public var displayName: String {
        switch self {
        case .serif: "Serif"
        case .sans: "Sans Serif"
        case .classic: "Classic"
        case .mono: "Monospaced"
        }
    }
}

public struct Run: Codable, Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var code = false
    public var link: String?
    public var fontSize: Int?
    public var letterSpacing: Double?

    public init(
        text: String,
        bold: Bool = false,
        italic: Bool = false,
        underline: Bool = false,
        strikethrough: Bool = false,
        code: Bool = false,
        link: String? = nil,
        fontSize: Int? = nil,
        letterSpacing: Double? = nil
    ) {
        self.text = text
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.strikethrough = strikethrough
        self.code = code
        self.link = link
        self.fontSize = fontSize
        self.letterSpacing = letterSpacing
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
        strikethrough = try c.decodeIfPresent(Bool.self, forKey: .strikethrough) ?? false
        code = try c.decodeIfPresent(Bool.self, forKey: .code) ?? false
        link = try c.decodeIfPresent(String.self, forKey: .link)
        fontSize = try c.decodeIfPresent(Int.self, forKey: .fontSize)
        letterSpacing = try c.decodeIfPresent(Double.self, forKey: .letterSpacing)
    }
}

public struct Block: Codable, Equatable, Sendable {
    public var style: ParagraphStyle
    public var list: ListKind?
    public var alignment: TextAlignment
    public var lineHeight: Double?
    public var runs: [Run]

    public init(style: ParagraphStyle = .body, list: ListKind? = nil, alignment: TextAlignment = .left, lineHeight: Double? = nil, runs: [Run] = []) {
        self.style = style
        self.list = list
        self.alignment = alignment
        self.lineHeight = lineHeight
        self.runs = runs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        style = try c.decodeIfPresent(ParagraphStyle.self, forKey: .style) ?? .body
        list = try c.decodeIfPresent(ListKind.self, forKey: .list)
        alignment = try c.decodeIfPresent(TextAlignment.self, forKey: .alignment) ?? .left
        lineHeight = try c.decodeIfPresent(Double.self, forKey: .lineHeight)
        runs = try c.decodeIfPresent([Run].self, forKey: .runs) ?? []
    }
}

public struct DocumentModel: Codable, Equatable, Sendable {
    public var appearance: Appearance
    public var blocks: [Block]

    public init(appearance: Appearance = .serif, blocks: [Block] = [Block()]) {
        self.appearance = appearance
        self.blocks = blocks
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance) ?? .serif
        blocks = try c.decodeIfPresent([Block].self, forKey: .blocks) ?? [Block()]
    }
}
