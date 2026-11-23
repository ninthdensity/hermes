import AppKit

/// Produces paper-ready output. List markers become literal text so they survive RTF and PDF.
public enum Exporter {
    public static func attributedString(for model: DocumentModel) -> NSAttributedString {
        let theme = Theme(appearance: model.appearance)
        let out = NSMutableAttributedString()
        var ordinal = 0
        for (index, block) in model.blocks.enumerated() {
            let paragraph = theme.paragraphStyle(block.style, list: block.list, alignment: block.alignment, lineHeight: block.lineHeight).mutableCopy() as! NSMutableParagraphStyle
            let color = theme.textColor(block.style, forExport: true)
            let base: [NSAttributedString.Key: Any] = [
                .font: theme.font(block.style, size: block.runs.first?.fontSize),
                .paragraphStyle: paragraph,
                .foregroundColor: color,
            ]
            switch block.list {
            case .number:
                ordinal += 1
                out.append(NSAttributedString(string: "\(ordinal).\t", attributes: base))
            case .bullet:
                ordinal = 0
                out.append(NSAttributedString(string: "•\t", attributes: base))
            case nil:
                ordinal = 0
            }
            if block.list != nil {
                paragraph.firstLineHeadIndent = paragraph.headIndent - Theme.listIndent
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: paragraph.headIndent)]
                paragraph.defaultTabInterval = Theme.listIndent
            }
            for run in block.runs where !run.text.isEmpty {
                var attrs = base
                if let spacing = run.letterSpacing { attrs[.kern] = spacing }
                attrs[.font] = theme.font(block.style, bold: run.bold, italic: run.italic, code: run.code, size: run.fontSize)
                if run.underline || run.link != nil { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
                if run.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                if run.code { attrs[.backgroundColor] = theme.codeBackgroundColor(forExport: true) }
                if let link = run.link { attrs[.link] = linkValue(link) }
                out.append(NSAttributedString(string: run.text, attributes: attrs))
            }
            if index < model.blocks.count - 1 {
                out.append(NSAttributedString(string: "\n", attributes: base))
            }
        }
        return out
    }

    public static func rtfData(for model: DocumentModel) throws -> Data {
        let s = NSMutableAttributedString(attributedString: attributedString(for: model))
        substituteNamedFonts(in: s, appearance: model.appearance)
        return try s.data(
            from: NSRange(location: 0, length: s.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
    }

    /// RTF refers to fonts by name, and the system's own faces (New York, SF) can't be named,
    /// so other apps would fall back to Times. Swap in installed families with matching traits.
    private static func substituteNamedFonts(in s: NSMutableAttributedString, appearance: Appearance) {
        let defaultFamily: String? = switch appearance {
        case .serif: "Georgia"
        case .sans: "Helvetica Neue"
        case .mono: "Menlo"
        case .classic: nil
        }
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let font = value as? NSFont, font.fontName.hasPrefix(".") else { return }
            let traits = font.fontDescriptor.symbolicTraits
            let targetFamily = traits.contains(.monoSpace) ? "Menlo" : defaultFamily
            guard let targetFamily else { return }
            var named = NSFontManager.shared.convert(font, toFamily: targetFamily)
            if traits.contains(.bold) { named = NSFontManager.shared.convert(named, toHaveTrait: .boldFontMask) }
            if traits.contains(.italic) { named = NSFontManager.shared.convert(named, toHaveTrait: .italicFontMask) }
            s.addAttribute(.font, value: named, range: range)
        }
    }

    public static func plainTextData(for model: DocumentModel) throws -> Data {
        Data(try HermesCore.plainText(model).utf8)
    }

    /// A TextKit 1 view sized to the printable width; TextKit 1 has the most reliable pagination.
    public static func printView(for model: DocumentModel, printInfo: NSPrintInfo) -> NSTextView {
        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let storage = NSTextStorage(attributedString: attributedString(for: model))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        view.appearance = NSAppearance(named: .aqua)
        view.textContainerInset = .zero
        view.minSize = NSSize(width: width, height: 0)
        view.maxSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.drawsBackground = false
        view.linkTextAttributes = [.underlineStyle: NSUnderlineStyle.single.rawValue]
        layout.ensureLayout(for: container)
        view.sizeToFit()
        return view
    }

    public static func configureForPaper(_ printInfo: NSPrintInfo) {
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false
    }

    public static func pdfData(for model: DocumentModel, printInfo: NSPrintInfo) throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try writePDF(for: model, printInfo: printInfo, to: url)
        return try Data(contentsOf: url)
    }

    /// Runs a real print job to a file; an in-memory PDF operation would not paginate.
    public static func writePDF(for model: DocumentModel, printInfo: NSPrintInfo, to url: URL) throws {
        let info = printInfo.copy() as! NSPrintInfo
        configureForPaper(info)
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = NSPrintOperation(view: printView(for: model, printInfo: info), printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
