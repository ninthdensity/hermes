import AppKit
import Foundation
import PDFKit
import Testing
@testable import HermesKit

private func sampleModel() -> DocumentModel {
    DocumentModel(appearance: .classic, blocks: [
        Block(style: .title, runs: [Run(text: "On Writing")]),
        Block(style: .subtitle, runs: [Run(text: "A short essay")]),
        Block(style: .body, runs: [
            Run(text: "Plain, "),
            Run(text: "bold", bold: true),
            Run(text: ", "),
            Run(text: "italic", italic: true),
            Run(text: " and "),
            Run(text: "linked", underline: true, link: "https://example.com/"),
        ]),
        Block(style: .heading, runs: [Run(text: "Lists")]),
        Block(style: .body, list: .number, runs: [Run(text: "first")]),
        Block(style: .body, list: .number, runs: [Run(text: "second")]),
        Block(style: .body, list: .bullet, runs: [Run(text: "a bullet")]),
        Block(style: .quote, runs: [Run(text: "Ünïcödé — 日本語 🎉 עברית")]),
    ])
}

@Suite struct CoreBridge {
    @Test func fileRoundTripPreservesEverything() throws {
        let model = sampleModel()
        let data = try HermesCore.encodeFile(model)
        #expect(try HermesCore.decodeFile(data) == model)
    }

    @Test func foreignFilesAreRejectedWithAMessage() {
        #expect(throws: HermesCoreError(message: "This file isn't a hermes document.")) {
            try HermesCore.decodeFile(Data("{}".utf8))
        }
    }

    @Test func plainTextAndWordCount() throws {
        let text = try HermesCore.plainText(sampleModel())
        #expect(text.contains("1. first\n2. second\n• a bullet\n"))
        #expect(HermesCore.wordCount("one two, three") == 3)
    }

    @Test func directInterchangeEscapesSpecialCharactersAndRejectsNonFinite() throws {
        let tricky = DocumentModel(appearance: .mono, blocks: [
            Block(style: .heading, list: .bullet, alignment: .right, lineHeight: 1.5, runs: [
                Run(text: "Quotes \"here\" and \\backslash\\ and \t tab and \u{0007} bell — 日本語 🎉",
                    bold: true, italic: true, underline: true,
                    link: "https://example.com/a\"b\\c?x=1", fontSize: 22, letterSpacing: -0.5),
            ]),
        ])
        let encoded = try HermesCore.encodeFile(tricky)
        #expect(try HermesCore.decodeFile(encoded) == tricky)

        let badHeight = DocumentModel(blocks: [Block(lineHeight: .nan, runs: [Run(text: "x")])])
        #expect(throws: HermesCoreError.self) { try HermesCore.encodeFile(badHeight) }
        let badSpacing = DocumentModel(blocks: [Block(runs: [Run(text: "x", letterSpacing: .infinity)])])
        #expect(throws: HermesCoreError.self) { try HermesCore.encodeFile(badSpacing) }
    }
}

@Suite struct EditorConversion {
    @Test func lineHeightSurvivesRestylingFilesAndFragments() throws {
        let model = DocumentModel(blocks: [
            Block(alignment: .center, lineHeight: 1.75, runs: [Run(text: "Spaced", fontSize: 24)]),
            Block(runs: [Run(text: "Default")]),
        ])
        let engine = StyleEngine(appearance: .serif)
        let s = Converter.editorString(from: model, engine: engine)
        engine.appearance = .mono
        engine.restyleAll(s)
        #expect((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.75)
        #expect((s.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 1.35)
        #expect(Converter.model(from: s, appearance: .serif) == model)
        #expect(try HermesCore.decodeFile(HermesCore.encodeFile(model)) == model)
        let fragment = try #require(PasteNormalizer.fragmentData(for: s))
        let pasted = try #require(PasteNormalizer.string(fromFragment: fragment))
        #expect(Converter.model(from: pasted, appearance: .serif) == model)
    }

    @Test func customSizesAndAlignmentSurviveStylingAndConversion() throws {
        let model = DocumentModel(blocks: [
            Block(alignment: .center, runs: [Run(text: "Small ", fontSize: 12), Run(text: "large", bold: true, fontSize: 36)]),
            Block(alignment: .right, runs: [Run(text: "Right")]),
        ])
        let engine = StyleEngine(appearance: .serif)
        let s = Converter.editorString(from: model, engine: engine)
        engine.appearance = .mono
        engine.restyleAll(s)
        #expect((s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 12)
        #expect((s.attribute(.font, at: 6, effectiveRange: nil) as? NSFont)?.pointSize == 36)
        #expect((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
        #expect((s.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right)
        let converted = Converter.model(from: s, appearance: model.appearance)
        #expect(converted == model)
        #expect(try HermesCore.decodeFile(HermesCore.encodeFile(converted)) == model)
        let fragment = try #require(PasteNormalizer.fragmentData(for: s))
        let pasted = try #require(PasteNormalizer.string(fromFragment: fragment))
        #expect(Converter.model(from: pasted, appearance: model.appearance) == model)
    }

    @Test func modelSurvivesTheEditorRoundTrip() {
        let model = sampleModel()
        let engine = StyleEngine(appearance: model.appearance)
        let s = Converter.editorString(from: model, engine: engine)
        #expect(Converter.model(from: s, appearance: model.appearance) == model)
    }

    @Test func fontsAreDerivedFromSemanticAttributes() {
        let engine = StyleEngine(appearance: .sans)
        let s = Converter.editorString(from: sampleModel(), engine: engine)
        let boldIndex = (s.string as NSString).range(of: "bold").location
        let font = s.attribute(.font, at: boldIndex, effectiveRange: nil) as! NSFont
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let title = s.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
        #expect(title.pointSize > 25)
    }

    @Test func paragraphTakesStyleOfItsFirstCharacter() {
        let engine = StyleEngine(appearance: .serif)
        let s = Converter.editorString(from: DocumentModel(blocks: [
            Block(style: .heading, runs: [Run(text: "Head")]),
            Block(style: .body, runs: [Run(text: "body")]),
        ]), engine: engine)
        s.deleteCharacters(in: NSRange(location: 4, length: 1))
        engine.restyle(s, range: NSRange(location: 4, length: 0))
        let model = Converter.model(from: s, appearance: .serif)
        #expect(model.blocks == [Block(style: .heading, runs: [Run(text: "Headbody")])])
    }

    @Test func numberedListsRenumberAfterEdits() {
        let engine = StyleEngine(appearance: .serif)
        let items = (1...4).map { Block(list: .number, runs: [Run(text: "item \($0)")]) }
        let s = Converter.editorString(from: DocumentModel(blocks: items), engine: engine)
        func ordinals() -> [Int] {
            let ns = s.string as NSString
            var result: [Int] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
                result.append(s.attribute(.hermesListOrdinal, at: range.location, effectiveRange: nil) as? Int ?? 0)
            }
            return result
        }
        #expect(ordinals() == [1, 2, 3, 4])
        s.removeAttribute(.hermesList, range: NSRange(location: 0, length: 7))
        engine.restyle(s, range: NSRange(location: 0, length: 0))
        #expect(ordinals() == [0, 1, 2, 3])
    }

    @Test func trailingEmptyParagraphIsKept() {
        let s = NSAttributedString(string: "Hello\n", attributes: [.hermesStyle: "heading"])
        let model = Converter.model(from: s, appearance: .serif)
        #expect(model.blocks.count == 2)
        #expect(model.blocks[1] == Block(style: .body))
    }
}

@Suite struct Pasting {
    @Test func foreignRichTextKeepsOnlyMarks() {
        let foreign = NSMutableAttributedString(string: "Big ", attributes: [.font: NSFont.systemFont(ofSize: 40), .foregroundColor: NSColor.red])
        foreign.append(NSAttributedString(string: "bold\r\nnext", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        let pasted = PasteNormalizer.string(fromForeign: foreign, style: .heading, list: nil)
        #expect(pasted.string == "Big bold\nnext")
        #expect(pasted.attribute(.foregroundColor, at: 0, effectiveRange: nil) == nil)
        #expect(pasted.flag(.hermesBold, at: 4))
        #expect(!pasted.flag(.hermesBold, at: 0))
        #expect(pasted.paragraphStyleValue(at: 0) == .heading)
        #expect(pasted.paragraphStyleValue(at: 9) == .body)
    }

    @Test func fragmentsKeepParagraphStyles() throws {
        let engine = StyleEngine(appearance: .serif)
        let s = Converter.editorString(from: sampleModel(), engine: engine)
        let data = try #require(PasteNormalizer.fragmentData(for: s.attributedSubstring(from: NSRange(location: 0, length: 14))))
        let back = try #require(PasteNormalizer.string(fromFragment: data))
        #expect(back.string == "On Writing\nA s")
        #expect(back.paragraphStyleValue(at: 0) == .title)
        #expect(back.paragraphStyleValue(at: 11) == .subtitle)
    }
}

@Suite struct Exporting {
    @Test func lineHeightChangesLayoutAndSurvivesRTF() throws {
        let text = String(repeating: "A paragraph with several wrapped lines of text. ", count: 12)
        let single = DocumentModel(blocks: [Block(lineHeight: 1, runs: [Run(text: text)])])
        let double = DocumentModel(blocks: [Block(lineHeight: 2, runs: [Run(text: text)])])
        let shortView = Exporter.printView(for: single, printInfo: NSPrintInfo())
        let tallView = Exporter.printView(for: double, printInfo: NSPrintInfo())
        #expect(tallView.frame.height > shortView.frame.height * 1.6)
        let rtf = try NSAttributedString(data: Exporter.rtfData(for: double), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect((rtf.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.lineHeightMultiple == 2)
    }

    @Test func exportsKeepCustomSizesAndAlignment() throws {
        let model = DocumentModel(blocks: [
            Block(alignment: .center, runs: [Run(text: "Centered", fontSize: 36)]),
            Block(alignment: .right, runs: [Run(text: "Right", fontSize: 12)]),
        ])
        let paper = Exporter.attributedString(for: model)
        let rtf = try NSAttributedString(data: Exporter.rtfData(for: model), options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        for s in [paper, rtf] {
            #expect((s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 36)
            #expect((s.attribute(.font, at: 9, effectiveRange: nil) as? NSFont)?.pointSize == 12)
            #expect((s.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .center)
            #expect((s.attribute(.paragraphStyle, at: 9, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right)
        }
    }

    @Test func rtfContainsTextAndMarkers() throws {
        let rtf = try Exporter.rtfData(for: sampleModel())
        let back = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(back.string.contains("1.\tfirst"))
        #expect(back.string.contains("•\ta bullet"))
        var names = Set<String>()
        back.enumerateAttribute(.font, in: NSRange(location: 0, length: back.length)) { value, _, _ in
            if let font = value as? NSFont { names.insert(font.familyName ?? "") }
        }
        #expect(names == ["Charter"])
    }

    @Test func rtfNamesRealFontsForSystemFaces() throws {
        var model = sampleModel()
        model.appearance = .serif
        let rtf = String(decoding: try Exporter.rtfData(for: model), as: UTF8.self)
        #expect(rtf.contains("Georgia"))
        #expect(!rtf.contains(".NewYork"))
        #expect(rtf.contains("Georgia-Bold"))
    }

    @Test func pdfHasTextAndPaginates() throws {
        var model = sampleModel()
        let paragraph = Block(runs: [Run(text: String(repeating: "All work and no play makes a long document. ", count: 12))])
        model.blocks += Array(repeating: paragraph, count: 30)
        let data = try Exporter.pdfData(for: model, printInfo: NSPrintInfo())
        let pdf = try #require(PDFDocument(data: data))
        #expect(pdf.pageCount > 3)
        #expect(pdf.page(at: 0)?.string?.contains("On Writing") == true)
        if let dir = ProcessInfo.processInfo.environment["HERMES_TEST_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("sample.pdf"))
        }
    }
}

@Suite struct LetterSpacing {
    @Test func survivesFilesStylingFragmentsAndRTF() throws {
        let model = DocumentModel(blocks: [Block(runs: [
            Run(text: "Normal "), Run(text: "Wide", letterSpacing: 1.5), Run(text: "Tight", letterSpacing: -0.5),
        ])])
        #expect(try HermesCore.decodeFile(HermesCore.encodeFile(model)) == model)
        let engine = StyleEngine(appearance: .serif)
        let text = Converter.editorString(from: model, engine: engine)
        #expect(text.attribute(.kern, at: 7, effectiveRange: nil) as? Double == 1.5)
        #expect(text.attribute(.kern, at: 11, effectiveRange: nil) as? Double == -0.5)
        engine.appearance = .sans
        engine.restyleAll(text)
        #expect(Converter.model(from: text, appearance: .serif) == model)
        let fragment = try #require(PasteNormalizer.fragmentData(for: text))
        let pasted = try #require(PasteNormalizer.string(fromFragment: fragment))
        #expect(Converter.model(from: pasted, appearance: .serif) == model)
        let rtf = try Exporter.rtfData(for: model)
        let back = try NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        #expect(back.attribute(.kern, at: 7, effectiveRange: nil) as? Double == 1.5)
        #expect(back.attribute(.kern, at: 11, effectiveRange: nil) as? Double == -0.5)
        let printText = Exporter.attributedString(for: model)
        #expect(printText.attribute(.kern, at: 7, effectiveRange: nil) as? Double == 1.5)
    }
}

@Suite struct MarkdownBridge {
    @Test func decodeAndEncodeMarkdownThroughCore() throws {
        let input = Data("# Title\n\nSome **bold** and [linked](<https://example.com>).\n".utf8)
        let model = try #require(try HermesCore.decodeMarkdown(input))
        #expect(model.blocks.count == 2)
        #expect(model.blocks[0].style == .title)
        let encoded = String(decoding: try HermesCore.encodeMarkdown(model), as: UTF8.self)
        #expect(encoded.hasPrefix("# Title\n\n"))
        #expect(try HermesCore.decodeMarkdown(Data(encoded.utf8)) == model)
    }

    @Test func unsupportedMarkdownReturnsNilAndInvalidUTF8Throws() throws {
        let fenced = Data("```swift\nprint(1)\n```\n".utf8)
        #expect(try HermesCore.decodeMarkdown(fenced) == nil)
        #expect(throws: HermesCoreError(message: "Markdown files must use UTF-8 text.")) {
            try HermesCore.decodeMarkdown(Data([0xFF, 0xFE]))
        }
    }
}

@Suite struct ThemeAndConversionEdges {
    @Test func themeScalesMonospacedAndInvertsItalicInQuotes() {
        let serif = Theme(appearance: .serif)
        let mono = Theme(appearance: .mono)
        #expect(serif.font(.title).pointSize == 32)
        #expect(serif.font(.body).pointSize == 16)
        #expect(mono.font(.title).pointSize == (32 * 0.9).rounded())
        #expect(mono.font(.body).pointSize == (16 * 0.9).rounded())

        let quoteBase = serif.font(.quote, italic: false)
        let quoteItalic = serif.font(.quote, italic: true)
        #expect(quoteBase.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(!quoteItalic.fontDescriptor.symbolicTraits.contains(.italic))

        #expect(serif.font(.body, size: 2).pointSize == 8)
        #expect(serif.font(.body, size: 500).pointSize == 144)
        #expect(serif.textColor(.body, forExport: true) == .black)
        #expect(serif.textColor(.subtitle, forExport: true) != .black)
    }

    @Test func splittingNumberedListInTheMiddleRenumbersFollowingItems() {
        let engine = StyleEngine(appearance: .serif)
        let items = (1...5).map { Block(list: .number, runs: [Run(text: "item \($0)")]) }
        let s = Converter.editorString(from: DocumentModel(blocks: items), engine: engine)
        let middle = (s.string as NSString).range(of: "item 3")
        s.addAttribute(.hermesList, value: ListKind.bullet.rawValue, range: middle)
        engine.restyle(s, range: middle)

        let ns = s.string as NSString
        var ordinals: [Int] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byParagraphs) { _, range, _, _ in
            ordinals.append(s.attribute(.hermesListOrdinal, at: range.location, effectiveRange: nil) as? Int ?? 0)
        }
        #expect(ordinals == [1, 2, 0, 1, 2])
    }

    @Test func pasteNormalizerHandlesSemiboldMultilineAndCorruptFragments() {
        let semibold = NSFont.systemFont(ofSize: 15, weight: .semibold)
        let foreign = NSMutableAttributedString(string: "Semi", attributes: [
            .font: semibold,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .link: "   ",
        ])
        foreign.append(NSAttributedString(string: "\u{FFFC}\0 ok", attributes: [.link: "https://example.com"]))
        let normalized = PasteNormalizer.string(fromForeign: foreign, style: .body, list: nil)
        #expect(normalized.string == "Semi ok")
        #expect(normalized.flag(.hermesBold, at: 0))
        #expect(normalized.flag(.hermesUnderline, at: 0))
        #expect(normalized.attribute(.link, at: 0, effectiveRange: nil) == nil)
        #expect(normalized.attribute(.link, at: 5, effectiveRange: nil) != nil)

        let multiline = PasteNormalizer.string(fromPlain: "Heading\r\nFollowing\u{2029}Third", style: .heading, list: nil)
        #expect(multiline.string == "Heading\nFollowing\nThird")
        #expect(multiline.paragraphStyleValue(at: 0) == .heading)
        #expect(multiline.paragraphStyleValue(at: 8) == .body)
        #expect(multiline.paragraphStyleValue(at: 18) == .body)

        #expect(PasteNormalizer.string(fromFragment: Data("not json".utf8)) == nil)
    }

    @Test func rtfSubstitutesNamedFontsForSansAndMono() throws {
        var sansModel = sampleModel()
        sansModel.appearance = .sans
        let sansRTF = String(decoding: try Exporter.rtfData(for: sansModel), as: UTF8.self)
        #expect(sansRTF.contains("Helvetica"))
        #expect(!sansRTF.contains(".AppleSystemUIFont"))

        var monoModel = sampleModel()
        monoModel.appearance = .mono
        let monoRTF = String(decoding: try Exporter.rtfData(for: monoModel), as: UTF8.self)
        #expect(monoRTF.contains("Menlo"))
    }
}

@Suite struct CodeAndStrikethrough {
    @Test func survivesFilesStylingFragmentsPasteAndRTF() throws {
        let model = DocumentModel(appearance: .classic, blocks: [Block(runs: [
            Run(text: "Run "),
            Run(text: "cargo test", code: true),
            Run(text: " not "),
            Run(text: "old", strikethrough: true),
            Run(text: " "),
            Run(text: "deprecated()", bold: true, strikethrough: true, code: true),
        ])])
        #expect(try HermesCore.decodeFile(HermesCore.encodeFile(model)) == model)

        let engine = StyleEngine(appearance: .classic)
        let text = Converter.editorString(from: model, engine: engine)
        let codeRange = (text.string as NSString).range(of: "cargo test")
        let strikeRange = (text.string as NSString).range(of: "old")
        let codeFont = try #require(text.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont)
        #expect(codeFont.fontDescriptor.symbolicTraits.contains(.monoSpace))
        #expect(text.attribute(.backgroundColor, at: codeRange.location, effectiveRange: nil) != nil)
        #expect(text.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)

        engine.appearance = .serif
        engine.restyleAll(text)
        #expect(Converter.model(from: text, appearance: .classic) == model)

        let fragment = try #require(PasteNormalizer.fragmentData(for: text))
        let pasted = try #require(PasteNormalizer.string(fromFragment: fragment))
        #expect(Converter.model(from: pasted, appearance: .classic) == model)

        // Foreign rich text keeps strikethrough and mixed inline monospace, but not whole-block monospace.
        let mixedForeign = NSMutableAttributedString(string: "Prose ", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        mixedForeign.append(NSAttributedString(string: "fn()", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]))
        mixedForeign.append(NSAttributedString(string: " old", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
        ]))
        let normalizedMixed = PasteNormalizer.string(fromForeign: mixedForeign, style: .body, list: nil)
        #expect(!normalizedMixed.flag(.hermesCode, at: 0))
        #expect(normalizedMixed.flag(.hermesCode, at: 6))
        #expect(normalizedMixed.flag(.hermesStrikethrough, at: 11))

        let allMono = NSAttributedString(string: "terminal output", attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let normalizedAllMono = PasteNormalizer.string(fromForeign: allMono, style: .body, list: nil)
        #expect(!normalizedAllMono.flag(.hermesCode, at: 0))

        // RTF export substitutes Menlo for inline code across Classic, Serif, and Sans, and keeps strikethrough.
        for appearance in [Appearance.classic, .serif, .sans] {
            var m = model
            m.appearance = appearance
            let rtfData = try Exporter.rtfData(for: m)
            let rtfRaw = String(decoding: rtfData, as: UTF8.self)
            #expect(rtfRaw.contains("Menlo"))
            let back = try NSAttributedString(data: rtfData, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            let backStrike = (back.string as NSString).range(of: "old").location
            #expect(back.attribute(.strikethroughStyle, at: backStrike, effectiveRange: nil) as? Int == NSUnderlineStyle.single.rawValue)
        }

        // Markdown bridge round-trips inline code and strikethrough.
        let md = Data("Use `cargo test` and ~~manual~~ steps.\n".utf8)
        let mdModel = try #require(try HermesCore.decodeMarkdown(md))
        #expect(mdModel.blocks[0].runs.contains { $0.code && $0.text == "cargo test" })
        #expect(mdModel.blocks[0].runs.contains { $0.strikethrough && $0.text == "manual" })
        let reencoded = String(decoding: try HermesCore.encodeMarkdown(mdModel), as: UTF8.self)
        #expect(reencoded == "Use `cargo test` and ~~manual~~ steps.\n")
    }
}

@Suite struct SmartMarkdownTriggers {
    @Test func matchesBlockPrefixesOnlyAtParagraphStart() {
        #expect(SmartMarkdown.match(paragraphPrefix: "# ", trigger: " ") == .block(prefixLength: 2, action: .style(.title)))
        #expect(SmartMarkdown.match(paragraphPrefix: "## ", trigger: " ") == .block(prefixLength: 3, action: .style(.heading)))
        #expect(SmartMarkdown.match(paragraphPrefix: "### ", trigger: " ") == .block(prefixLength: 4, action: .style(.subheading)))
        #expect(SmartMarkdown.match(paragraphPrefix: "> ", trigger: " ") == .block(prefixLength: 2, action: .style(.quote)))
        #expect(SmartMarkdown.match(paragraphPrefix: "- ", trigger: " ") == .block(prefixLength: 2, action: .list(.bullet)))
        #expect(SmartMarkdown.match(paragraphPrefix: "* ", trigger: " ") == .block(prefixLength: 2, action: .list(.bullet)))
        #expect(SmartMarkdown.match(paragraphPrefix: "1. ", trigger: " ") == .block(prefixLength: 3, action: .list(.number)))

        #expect(SmartMarkdown.match(paragraphPrefix: "#### ", trigger: " ") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "2. ", trigger: " ") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "text # ", trigger: " ") == nil)
    }

    @Test func matchesInlineDelimitersWithUTF16AccuracyAndRejectsFalsePositives() {
        // Emoji 🎉 takes 2 UTF-16 code units.
        let emojiBold = SmartMarkdown.match(paragraphPrefix: "🎉 **hi**", trigger: "*")
        #expect(emojiBold == .inline(fullRange: NSRange(location: 3, length: 6), contentRange: NSRange(location: 5, length: 2), mark: .bold))

        #expect(SmartMarkdown.match(paragraphPrefix: "say __bold__", trigger: "_")
                == .inline(fullRange: NSRange(location: 4, length: 8), contentRange: NSRange(location: 6, length: 4), mark: .bold))
        #expect(SmartMarkdown.match(paragraphPrefix: "*italic*", trigger: "*")
                == .inline(fullRange: NSRange(location: 0, length: 8), contentRange: NSRange(location: 1, length: 6), mark: .italic))
        #expect(SmartMarkdown.match(paragraphPrefix: "(_em_)", trigger: "_")
                == nil) // last char is ")", not "_"
        #expect(SmartMarkdown.match(paragraphPrefix: "(_em_", trigger: "_")
                == .inline(fullRange: NSRange(location: 1, length: 4), contentRange: NSRange(location: 2, length: 2), mark: .italic))
        #expect(SmartMarkdown.match(paragraphPrefix: "~~gone~~", trigger: "~")
                == .inline(fullRange: NSRange(location: 0, length: 8), contentRange: NSRange(location: 2, length: 4), mark: .strikethrough))
        #expect(SmartMarkdown.match(paragraphPrefix: "run `ls -la`", trigger: "`")
                == .inline(fullRange: NSRange(location: 4, length: 8), contentRange: NSRange(location: 5, length: 6), mark: .code))

        // Anti-false-positive guards:
        #expect(SmartMarkdown.match(paragraphPrefix: "**bold*", trigger: "*") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "__bold_", trigger: "_") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "2 * 3 *", trigger: "*") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "* spaced*", trigger: "*") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "snake_case_", trigger: "_") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "foo__bar__", trigger: "_") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "****", trigger: "*") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "~~~~", trigger: "~") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "``", trigger: "`") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "```", trigger: "`") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "```code`", trigger: "`") == nil)
        #expect(SmartMarkdown.match(paragraphPrefix: "~single~", trigger: "~") == nil)
    }
}

@Suite struct UpdateChecking {
    @Test func parsesAndComparesSemanticVersions() throws {
        let v010 = try #require(SemanticVersion("0.1.0"))
        let v020 = try #require(SemanticVersion("v0.2.0"))
        let v020Beta = try #require(SemanticVersion("v0.2.0-beta.1"))
        let v020Beta2 = try #require(SemanticVersion("0.2.0-beta.2"))
        let v020Build = try #require(SemanticVersion("0.2.0+42"))
        let v10 = try #require(SemanticVersion("1.0"))

        #expect(v010 < v020Beta)
        #expect(v020Beta < v020Beta2)
        #expect(v020Beta2 < v020)
        #expect(v020 == v020Build)
        #expect(v020 < v10)
        #expect(v10.description == "1.0.0")

        #expect(SemanticVersion("") == nil)
        #expect(SemanticVersion("1") == nil)
        #expect(SemanticVersion("1.2.3.4") == nil)
        #expect(SemanticVersion("1.2.x") == nil)
        #expect(SemanticVersion("1.2.0-") == nil)
    }

    @Test func buildsAndValidatesGitHubReleaseURLs() throws {
        let url = try UpdateChecker.latestReleaseURL(forRepository: "ninthdensity/hermes")
        #expect(url.absoluteString == "https://api.github.com/repos/ninthdensity/hermes/releases/latest")

        #expect(throws: UpdateCheckerError.self) {
            try UpdateChecker.latestReleaseURL(forRepository: "invalid-repo")
        }
        #expect(throws: UpdateCheckerError.self) {
            try UpdateChecker.latestReleaseURL(forRepository: "owner/repo/extra")
        }
        #expect(throws: UpdateCheckerError.self) {
            try UpdateChecker.latestReleaseURL(forRepository: "../escape/repo")
        }
    }

    @Test func parsesGitHubReleaseAndSelectsPreferredAsset() throws {
        let json = """
        {
          "tag_name": "v0.2.0",
          "name": "Hermes 0.2.0",
          "body": "  - Focus Mode\\n  - Bug fixes  ",
          "html_url": "https://github.com/ninthdensity/hermes/releases/tag/v0.2.0",
          "published_at": "2026-11-23T18:00:00Z",
          "prerelease": false,
          "draft": false,
          "assets": [
            {
              "name": "checksums.txt",
              "browser_download_url": "https://github.com/ninthdensity/hermes/releases/download/v0.2.0/checksums.txt",
              "size": 128,
              "content_type": "text/plain"
            },
            {
              "name": "insecure.zip",
              "browser_download_url": "http://example.com/insecure.zip",
              "size": 1000,
              "content_type": "application/zip"
            },
            {
              "name": "Hermes-Writer-0.2.0-macos.zip",
              "browser_download_url": "https://github.com/ninthdensity/hermes/releases/download/v0.2.0/Hermes-Writer-0.2.0-macos.zip",
              "size": 5242880,
              "content_type": "application/zip"
            }
          ]
        }
        """
        let release = try UpdateChecker.parseGitHubRelease(data: Data(json.utf8))
        #expect(release.version == SemanticVersion(major: 0, minor: 2, patch: 0))
        #expect(release.notes == "- Focus Mode\n  - Bug fixes")
        #expect(release.assets.count == 2) // HTTP asset filtered out
        #expect(release.preferredDownloadAsset?.name == "Hermes-Writer-0.2.0-macos.zip")

        let current = SemanticVersion(major: 0, minor: 1, patch: 0)
        #expect(UpdateChecker.evaluate(release: release, currentVersion: current) == .updateAvailable(release))
        #expect(UpdateChecker.evaluate(release: release, currentVersion: SemanticVersion(major: 0, minor: 2, patch: 0))
                == .upToDate(currentVersion: SemanticVersion(major: 0, minor: 2, patch: 0), latestVersion: release.version))
        // Skipped version suppresses automatic check, but manual check (includeSkipped: true) still shows it.
        #expect(UpdateChecker.evaluate(release: release, currentVersion: current, skippedVersion: "v0.2.0", includeSkipped: false)
                == .upToDate(currentVersion: current, latestVersion: release.version))
        #expect(UpdateChecker.evaluate(release: release, currentVersion: current, skippedVersion: "v0.2.0", includeSkipped: true)
                == .updateAvailable(release))
    }

    @Test func throttlesAutomaticChecksAndValidatesBundles() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(UpdateChecker.shouldPerformAutomaticCheck(lastCheckDate: nil, now: now))
        #expect(!UpdateChecker.shouldPerformAutomaticCheck(lastCheckDate: now.addingTimeInterval(-3600), now: now))
        #expect(UpdateChecker.shouldPerformAutomaticCheck(lastCheckDate: now.addingTimeInterval(-90_000), now: now))

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-bundle-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        let app = temp.appendingPathComponent("Hermes Writer.app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)

        let plist: [String: Any] = [
            "CFBundleIdentifier": "dev.hermes.hermes",
            "CFBundleExecutable": "hermes",
        ]
        let plistData = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try plistData.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exec = macOS.appendingPathComponent("hermes")
        try Data("#!/bin/sh\n".utf8).write(to: exec)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)

        try UpdateChecker.validateExtractedAppBundle(at: app, expectedBundleIdentifier: "dev.hermes.hermes")
        #expect(throws: UpdateCheckerError.self) {
            try UpdateChecker.validateExtractedAppBundle(at: app, expectedBundleIdentifier: "dev.other.app")
        }
    }
}

