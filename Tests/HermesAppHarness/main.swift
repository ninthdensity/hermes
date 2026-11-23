import AppKit
@testable import HermesApp
import HermesKit

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
var failures = 0

func check(_ condition: Bool, _ label: String, line: Int = #line) {
    print(condition ? "✔ \(label)" : "✘ \(label) (line \(line))")
    if !condition { failures += 1 }
}

func pump(_ seconds: TimeInterval = 0.05) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

final class FileDrag: NSObject, NSDraggingInfo {
    let draggingPasteboard = NSPasteboard.withUniqueName()
    let draggingSourceOperationMask: NSDragOperation = [.copy, .move]
    let draggingDestinationWindow: NSWindow? = nil
    let draggingLocation = NSPoint.zero
    let draggedImageLocation = NSPoint.zero
    let draggedImage: NSImage? = nil
    let draggingSource: Any? = nil
    let draggingSequenceNumber = 0
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    let springLoadingHighlight: NSSpringLoadingHighlight = .none

    init(_ url: URL) {
        super.init()
        let item = NSPasteboardItem()
        item.setString(url.absoluteString, forType: .fileURL)
        item.setString(url.path, forType: .string)
        draggingPasteboard.writeObjects([item])
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                               searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                               using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

func checkFileDrop(window: NSWindow, textView: EditorTextView, url: URL) {
    let frame = window.contentView!
    let controller = NSDocumentController.shared
    let drag = FileDrag(url)
    let originalText = textView.string
    check(frame.registeredDraggedTypes.contains(.fileURL), "the window frame registers for Finder files")
    check(textView.registeredDraggedTypes.contains(.fileURL), "the writing area registers for Finder files")
    check(textView.draggingEntered(drag) == .copy && textView.prepareForDragOperation(drag)
          && textView.performDragOperation(drag), "dropping Markdown on the writing area opens a document")
    let deadline = Date().addingTimeInterval(3)
    while controller.document(for: url) == nil && Date() < deadline { pump() }
    let opened = controller.document(for: url) as? Document
    check(opened?.currentModel().blocks.first?.style == .title && textView.string == originalText,
          "the drop uses normal document opening and leaves the original draft intact")
    check(frame.draggingEntered(drag) == .copy && frame.prepareForDragOperation(drag)
          && frame.performDragOperation(drag), "dropping on the window frame also opens the document")
    pump()
    check(opened != nil && controller.document(for: url) === opened, "dropping an open document reuses its window")

    let unsupported = FileDrag(url.deletingPathExtension().appendingPathExtension("pdf"))
    check(textView.draggingEntered(unsupported).isEmpty && !textView.performDragOperation(unsupported),
          "unsupported files are rejected even if their drag also contains a text path")
    opened?.close()
}

final class Editor {
    let document = Document()
    let window: NSWindow
    let textView: EditorTextView

    init() {
        document.makeWindowControllers()
        window = document.windowControllers[0].window!
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderFront(nil)
        textView = document.editor!.textView
        window.makeFirstResponder(textView)
    }

    func type(_ s: String) { textView.insertText(s, replacementRange: textView.selectedRange()) }
    func enter() { textView.insertNewline(nil) }
    func style(_ style: ParagraphStyle) {
        let item = NSMenuItem()
        item.tag = ParagraphStyle.allCases.firstIndex(of: style)!
        textView.applyParagraphStyle(item)
    }
    func moveToEnd() { textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0)) }
    var model: DocumentModel { document.currentModel() }
    var state: FormattingState { textView.formattingState }

    func snapshot(_ name: String) {
        textView.scrollToBeginningOfDocument(nil)
        pump()
        let frameView = window.contentView!.superview!
        frameView.layoutSubtreeIfNeeded()
        frameView.display()
        let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds)!
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        try! rep.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent("\(name).png"))
    }
}

_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
NSApp.mainMenu = MainMenu.build()

// MARK: Markdown open, edit, and save

let markdownType = Document.markdownType.identifier
let markdownURL = outputDirectory.appendingPathComponent("Draft-\(UUID().uuidString).md")
let markdownInput = Data("# Draft\n\nA **bold** paragraph with `code`, ~~old~~, and [a link](./related.md).\n\n- First\n- Second\n".utf8)
try markdownInput.write(to: markdownURL)
let markdownDocument: Document
if Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") != nil {
    let controller = NSDocumentController.shared
    let detectedType = try controller.typeForContents(of: markdownURL)
    check(detectedType == markdownType && controller.defaultType == Document.hermesType.identifier,
          "macOS recognizes .md in File Open while File New defaults to Hermes")
    markdownDocument = try controller.makeDocument(withContentsOf: markdownURL, ofType: detectedType) as! Document
} else {
    markdownDocument = try Document(contentsOf: markdownURL, ofType: markdownType)
}
markdownDocument.makeWindowControllers()
let markdownEditor = markdownDocument.editor!.textView!
check(!markdownEditor.isMarkdownSource && markdownDocument.currentModel().blocks.first?.style == .title
      && markdownDocument.currentModel().blocks[1].runs.contains(where: { $0.code && $0.text == "code" })
      && markdownDocument.currentModel().blocks[1].runs.contains(where: { $0.strikethrough && $0.text == "old" }),
      "ordinary Markdown including inline code and strikethrough opens in the formatted editor")
let uneditedMarkdown = try markdownDocument.data(ofType: markdownType)
check(uneditedMarkdown == markdownInput, "saving untouched Markdown preserves its original bytes")
let draftRange = (markdownEditor.string as NSString).range(of: "Draft")
markdownEditor.setSelectedRange(draftRange)
markdownEditor.insertText("Revised draft", replacementRange: draftRange)
let paragraphWord = (markdownEditor.string as NSString).range(of: "paragraph")
markdownEditor.setSelectedRange(paragraphWord)
markdownEditor.toggleItalic(nil)
var markdownSaveFinished = false
var markdownSaveError: Error?
markdownDocument.save(to: markdownURL, ofType: markdownDocument.fileType!, for: .saveOperation) {
    markdownSaveError = $0
    markdownSaveFinished = true
}
while !markdownSaveFinished { pump() }
if let markdownSaveError { throw markdownSaveError }
let savedMarkdown = try String(contentsOf: markdownURL, encoding: .utf8)
let reopenedMarkdown = try Document(contentsOf: markdownURL, ofType: markdownType)
check(savedMarkdown.hasPrefix("# Revised draft\n") && savedMarkdown.contains("**bold**")
      && savedMarkdown.contains("`code`") && savedMarkdown.contains("~~old~~")
      && reopenedMarkdown.model.blocks[1].runs.contains(where: { $0.italic && $0.text == "paragraph" })
      && reopenedMarkdown.model == markdownDocument.currentModel(),
      "saving edits writes standard Markdown and keeps the document structure on reopen")
check(markdownDocument.writableTypes(for: .saveAsOperation) == [markdownType]
      && Document().writableTypes(for: .saveOperation) == [Document.hermesType.identifier],
      "Markdown saves as Markdown and new Hermes documents keep their own format")
let exportHermesItem = NSMenuItem(title: "Hermes Document…", action: #selector(Document.exportHermes(_:)), keyEquivalent: "")
check(markdownDocument.validateUserInterfaceItem(exportHermesItem) && !Document().validateUserInterfaceItem(exportHermesItem),
      "Export to Hermes Document is enabled only for Markdown documents")
let mdSubtitleItem = NSMenuItem(title: "Subtitle", action: #selector(EditorTextView.applyParagraphStyle(_:)), keyEquivalent: "")
mdSubtitleItem.tag = ParagraphStyle.allCases.firstIndex(of: .subtitle)!
let mdUnderlineItem = NSMenuItem(title: "Underline", action: #selector(EditorTextView.toggleUnderline(_:)), keyEquivalent: "")
let mdStrikeItem = NSMenuItem(title: "Strikethrough", action: #selector(EditorTextView.toggleStrikethrough(_:)), keyEquivalent: "")
let mdCodeItem = NSMenuItem(title: "Inline Code", action: #selector(EditorTextView.toggleCode(_:)), keyEquivalent: "")
let mdAlignItem = NSMenuItem(title: "Center", action: #selector(EditorTextView.alignCenter(_:)), keyEquivalent: "")
let mdAppearanceItem = NSMenuItem(title: "Mono", action: #selector(EditorViewController.applyAppearance(_:)), keyEquivalent: "")
mdAppearanceItem.tag = Appearance.allCases.firstIndex(of: .mono)!
check(!markdownEditor.validateMenuItem(mdSubtitleItem)
      && !markdownEditor.validateMenuItem(mdUnderlineItem)
      && markdownEditor.validateMenuItem(mdStrikeItem)
      && markdownEditor.validateMenuItem(mdCodeItem)
      && !markdownEditor.validateMenuItem(mdAlignItem)
      && !markdownDocument.editor!.validateMenuItem(mdAppearanceItem),
      "Markdown mode keeps Strikethrough and Inline Code enabled while disabling Subtitle, Underline, Alignment and Typeface")
let mdPanel = FormatPanelController(editor: markdownDocument.editor!)
_ = mdPanel.view
mdPanel.viewWillAppear()
let mdSteppers = descendants(of: mdPanel.view).compactMap { $0 as? NumericStepperControl }
let mdMarks = descendants(of: mdPanel.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 5 }!
check(mdSteppers.count == 3 && mdSteppers.allSatisfy { !$0.field.isEnabled && !$0.stepper.isEnabled }
      && !mdMarks.isEnabled(forSegment: 2) && mdMarks.isEnabled(forSegment: 3) && mdMarks.isEnabled(forSegment: 4),
      "Markdown mode disables Size, Letter spacing, Line height and Underline while keeping Strikethrough and Inline Code enabled")
markdownDocument.close()

let sourceURL = outputDirectory.appendingPathComponent("Source-\(UUID().uuidString).md")
let originalSource = "\u{FEFF}---\r\ntitle: Draft\r\n---\r\n\r\n```sh\r\nprintf hello\r\n```\r\n"
let originalSourceBytes = Data(originalSource.utf8)
try originalSourceBytes.write(to: sourceURL)
let sourceDocument = try Document(contentsOf: sourceURL, ofType: markdownType)
sourceDocument.makeWindowControllers()
let sourceEditor = sourceDocument.editor!.textView!
let uneditedSource = try sourceDocument.data(ofType: markdownType)
check(sourceEditor.isMarkdownSource && uneditedSource == originalSourceBytes,
      "front matter and code fences open as editable source without rewriting original bytes")
let sourceHeader = (sourceDocument.windowControllers[0].window as! EditorWindow).header!
let sourcePopup = sourceHeader.subviews.compactMap { $0 as? NSPopUpButton }.first!
let sourceFormatButton = sourceHeader.subviews.compactMap { $0 as? NSButton }.first { $0.accessibilityLabel() == "Format" }!
check(sourcePopup.titleOfSelectedItem == "Markdown Source" && !sourcePopup.isEnabled && !sourceFormatButton.isEnabled
      && !sourceEditor.isAutomaticQuoteSubstitutionEnabled && sourceEditor.writablePasteboardTypes == [.string],
      "Markdown source mode locks formatting controls, disables smart substitutions and uses plain text clipboard")
check(sourceEditor.registeredDraggedTypes.contains(.fileURL), "Markdown source mode still accepts dropped files")
let sourceRange = (sourceEditor.string as NSString).range(of: "hello")
sourceEditor.setSelectedRange(sourceRange)
sourceEditor.insertText("world", replacementRange: sourceRange)
let editedSource = try sourceDocument.data(ofType: markdownType)
check(editedSource == Data(originalSource.replacingOccurrences(of: "hello", with: "world").utf8),
      "editing Markdown source preserves BOM, front matter, code fences and line endings")
sourceDocument.close()

// MARK: Custom window behavior

let chrome = Editor()
let chromeWindow = chrome.window as! EditorWindow
check(!chromeWindow.styleMask.contains(.titled) && chromeWindow.frame.size == NSSize(width: 860, height: 720),
      "square window opens at its intended size without a system title bar")
chromeWindow.makeKeyAndOrderFront(nil)
check(chromeWindow.canBecomeKey && chromeWindow.canBecomeMain && chromeWindow.makeFirstResponder(chrome.textView)
      && chromeWindow.firstResponder === chrome.textView,
      "the custom frame accepts key/main status and the editor responder")
if Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") != nil {
    checkFileDrop(window: chromeWindow, textView: chrome.textView, url: markdownURL)
}
// Exercise the actual tracking callbacks and compare rendered controls, including group hover.
let buttonGroup = chromeWindow.header!.windowButtonGroup
func renderedButton(_ button: NSButton) -> Data {
    let bitmap = button.bitmapImageRepForCachingDisplay(in: button.bounds)!
    button.cacheDisplay(in: button.bounds, to: bitmap)
    return bitmap.representation(using: .png, properties: [:])!
}
let buttonOrder: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
func hoverEvent(_ type: NSEvent.EventType) -> NSEvent {
    NSEvent.enterExitEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                          windowNumber: chromeWindow.windowNumber, context: nil,
                          eventNumber: 0, trackingNumber: 0, userData: nil)!
}
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    chromeWindow.appearance = NSAppearance(named: appearance)
    buttonGroup.mouseExited(with: hoverEvent(.mouseExited))
    let idle = buttonOrder.map { renderedButton(buttonGroup.buttons[$0]!) }
    buttonGroup.mouseEntered(with: hoverEvent(.mouseEntered))
    let hovered = buttonOrder.map { renderedButton(buttonGroup.buttons[$0]!) }
    check(zip(idle, hovered).allSatisfy { $0 != $1 }, "hover reveals all three window controls in \(appearance.rawValue)")
    for (index, image) in hovered.enumerated() {
        try image.write(to: outputDirectory.appendingPathComponent("window-control-\(index)-hover-\(appearance.rawValue).png"))
    }
    let pressed = buttonOrder.map { type -> Data in
        let button = buttonGroup.buttons[type]!
        button.highlight(true)
        let image = renderedButton(button)
        button.highlight(false)
        return image
    }
    check(zip(hovered, pressed).allSatisfy { $0 != $1 }, "pressing each window control provides visible feedback in \(appearance.rawValue)")
    buttonGroup.mouseExited(with: hoverEvent(.mouseExited))
    check(buttonOrder.enumerated().allSatisfy { renderedButton(buttonGroup.buttons[$0.element]!) == idle[$0.offset] },
          "leaving the window controls clears every hover symbol in \(appearance.rawValue)")
}
chromeWindow.appearance = nil
let closeControl = buttonGroup.buttons[.closeButton]!
let cleanControl = renderedButton(closeControl)
chromeWindow.isDocumentEdited = true
check(renderedButton(closeControl) != cleanControl, "the close control retains its unsaved-document indicator")
chromeWindow.isDocumentEdited = false
chromeWindow.title = "A Document.hrms"
chromeWindow.subtitle = "125 words"
chromeWindow.isDocumentEdited = true
check(chromeWindow.header?.documentTitle.stringValue == "A Document.hrms — Edited" && chromeWindow.header?.wordCount.stringValue == "125 words",
      "document title, edited state and word count update in the custom header")
let titleAttributes = chromeWindow.header!.documentTitle.attributedStringValue
let editedSuffix = (titleAttributes.string as NSString).range(of: " — Edited")
check(titleAttributes.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor == .labelColor
      && titleAttributes.attribute(.foregroundColor, at: editedSuffix.location, effectiveRange: nil) as? NSColor == .secondaryLabelColor,
      "the Edited suffix uses secondary text while the document name stays primary")
for appearance in [NSAppearance.Name.aqua, .darkAqua] {
    chromeWindow.appearance = NSAppearance(named: appearance)
    chrome.snapshot("document-title-\(appearance.rawValue)")
}
chromeWindow.appearance = nil
_ = chromeWindow.makeFirstResponder(chromeWindow)
let chromeController = chrome.document.windowControllers[0] as! EditorWindowController
chromeController.windowDidEnterFullScreen(Notification(name: NSWindow.didEnterFullScreenNotification, object: chromeWindow))
check(chromeWindow.firstResponder === chrome.textView, "entering full screen restores typing focus")
_ = chromeWindow.makeFirstResponder(chromeWindow)
chromeController.windowDidExitFullScreen(Notification(name: NSWindow.didExitFullScreenNotification, object: chromeWindow))
check(chromeWindow.firstResponder === chrome.textView, "leaving full screen restores typing focus")
let originalFrame = chromeWindow.frame
chromeWindow.setContentSize(NSSize(width: 520, height: 400))
chromeWindow.contentView?.layoutSubtreeIfNeeded()
check(chromeWindow.contentView?.bounds.size == NSSize(width: 520, height: 400)
      && chrome.textView.enclosingScrollView!.frame.width == 518,
      "resizing the square frame resizes the editor inside its outline")
chromeWindow.setFrame(originalFrame, display: false)
chromeWindow.isDocumentEdited = false
chromeWindow.performMiniaturize(nil)
pump()
check(chromeWindow.isMiniaturized, "the custom window supports standard minimization")
chromeWindow.orderOut(nil)
let closing = Editor()
(closing.window as! EditorWindow).standardWindowButton(.closeButton)!.performClick(nil)
pump()
check(!closing.window.isVisible, "the custom close button uses normal document closing")

let minimizing = Editor()
(minimizing.window as! EditorWindow).standardWindowButton(.miniaturizeButton)!.performClick(nil)
pump()
check(minimizing.window.isMiniaturized, "clicking the minimize control minimizes its window")
minimizing.window.orderOut(nil)

// MARK: Renaming from the document title

let renaming = Editor()
renaming.type("Keep this draft and its formatting.")
let renameTitle = (renaming.window as! EditorWindow).header!.documentTitle
func doubleClickTitle() {
    let event = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0,
                                  windowNumber: renaming.window.windowNumber, context: nil, eventNumber: 0,
                                  clickCount: 2, pressure: 1)!
    renameTitle.mouseDown(with: event)
    pump()
}
let beforeRenameFrame = renaming.window.frame
doubleClickTitle()
check(renaming.window.attachedSheet != nil && renaming.window.frame.size == beforeRenameFrame.size,
      "double-clicking the document name opens Rename without zooming the window")
let renameSheet = renaming.window.attachedSheet!
let renameViews = descendants(of: renameSheet.contentView!)
let renameField = renameViews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!
renameField.stringValue = "Named Draft"
renameViews.compactMap { $0 as? NSButton }.first { $0.title == "Rename" }!.performClick(nil)
pump()
check(renaming.document.displayName == "Named Draft" && renaming.document.fileURL == nil
      && renaming.window.title == "Named Draft" && renaming.document.isDocumentEdited,
      "renaming an unsaved draft updates its title and preserves its unsaved contents")
doubleClickTitle()
let cancelViews = descendants(of: renaming.window.attachedSheet!.contentView!)
cancelViews.compactMap { $0 as? NSTextField }.first { $0.isEditable }!.stringValue = "Discard this name"
cancelViews.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" }!.performClick(nil)
pump()
check(renaming.document.displayName == "Named Draft", "canceling Rename preserves the current name")
let renameDirectory = outputDirectory.appendingPathComponent("rename-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: renameDirectory, withIntermediateDirectories: true)
let beforeRenameURL = renameDirectory.appendingPathComponent("Named Draft.hrms")
var renameSaveFinished = false
var renameError: Error?
renaming.document.save(to: beforeRenameURL, ofType: "dev.hermes.hrms", for: .saveOperation) {
    renameError = $0
    renameSaveFinished = true
}
while !renameSaveFinished { pump() }
if let renameError { throw renameError }
var moveFinished = false
renaming.document.rename(to: "Named File") { renameError = $0; moveFinished = true }
while !moveFinished { pump() }
let afterRenameURL = renameDirectory.appendingPathComponent("Named File.hrms")
check(renameError == nil && renaming.document.fileURL == afterRenameURL
      && FileManager.default.fileExists(atPath: afterRenameURL.path)
      && !FileManager.default.fileExists(atPath: beforeRenameURL.path)
      && renaming.window.title.contains("Named File"),
      "renaming a saved document moves its file, preserves its extension, and updates the header")
check(try HermesCore.decodeFile(Data(contentsOf: afterRenameURL)) == renaming.model,
      "renaming a document preserves its saved contents and formatting")
let occupiedURL = renameDirectory.appendingPathComponent("Occupied.hrms")
let occupiedData = Data("Keep the other file".utf8)
try occupiedData.write(to: occupiedURL)
renaming.document.rename(to: "Occupied") { renameError = $0 }
let occupiedDataAfterRename = try Data(contentsOf: occupiedURL)
check((renameError as NSError?)?.code == NSFileWriteFileExistsError
      && occupiedDataAfterRename == occupiedData && renaming.document.fileURL == afterRenameURL,
      "renaming refuses an existing filename without overwriting another document")
renaming.window.orderOut(nil)

// MARK: Normal keyboard editing

let keyboard = Editor()
var expectedTyping = ""
var typingErrors: [String] = []
func typeKeys(_ string: String) {
    for character in string {
        if character == "\n" {
            keyboard.textView.insertNewline(nil)
        } else {
            keyboard.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        expectedTyping.append(character)
        pump(0.005)
        let caret = keyboard.textView.selectedRange()
        if keyboard.textView.string != expectedTyping || caret != NSRange(location: expectedTyping.utf16.count, length: 0) {
            typingErrors.append("after \(String(reflecting: character)): caret \(caret), text \(String(reflecting: keyboard.textView.string))")
        }
    }
}
typeKeys("Writing should stay on the same line.\nThis is the second paragraph.\nThird paragraph.")
check(typingErrors.isEmpty, "typing one character at a time keeps the text and caret in order: \(typingErrors.prefix(2))")
let originalKeyboardText = keyboard.textView.string
let insertion = (originalKeyboardText as NSString).range(of: "stay").location
keyboard.textView.setSelectedRange(NSRange(location: insertion, length: 0))
var insertionOffset = insertion
var middleErrors: [String] = []
for character in "always " {
    keyboard.textView.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
    insertionOffset += String(character).utf16.count
    pump(0.005)
    if keyboard.textView.selectedRange() != NSRange(location: insertionOffset, length: 0) {
        middleErrors.append("expected \(insertionOffset), got \(keyboard.textView.selectedRange())")
    }
}
check(middleErrors.isEmpty && keyboard.textView.string == originalKeyboardText.replacingOccurrences(of: "stay", with: "always stay"),
      "editing in the middle of a paragraph keeps the caret at the insertion: \(middleErrors.prefix(2))")
keyboard.textView.textLayoutManager!.ensureLayout(for: keyboard.textView.textLayoutManager!.documentRange)
print("  keyboard layout: frame \(keyboard.textView.frame.size), inset \(keyboard.textView.textContainerInset), container \(keyboard.textView.textContainer!.containerSize)")
check(keyboard.textView.textContainer!.containerSize.width >= 400, "normal window keeps a usable text column")
keyboard.snapshot("keyboard-editing")

// Run the native key-event path as well as NSTextInputClient insertion.
let nativeKeyboard = Editor()
nativeKeyboard.type("Before after\nAnother paragraph")
nativeKeyboard.textView.setSelectedRange(NSRange(location: 7, length: 0))
func pressEditingKey(_ characters: String, code: UInt16) {
    let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                windowNumber: nativeKeyboard.window.windowNumber, context: nil,
                                characters: characters, charactersIgnoringModifiers: characters,
                                isARepeat: false, keyCode: code)!
    nativeKeyboard.textView.keyDown(with: event)
    pump()
}
pressEditingKey("x", code: 7)
check(nativeKeyboard.textView.string == "Before xafter\nAnother paragraph" && nativeKeyboard.textView.selectedRange().location == 8,
      "native typing in an existing paragraph keeps the insertion point")
pressEditingKey("\r", code: 36)
pressEditingKey("y", code: 16)
check(nativeKeyboard.textView.string == "Before x\nyafter\nAnother paragraph" && nativeKeyboard.textView.selectedRange().location == 10,
      "Return splits a paragraph once and subsequent typing stays at the new caret")
pressEditingKey("\u{7F}", code: 51)
check(nativeKeyboard.textView.string == "Before x\nafter\nAnother paragraph" && nativeKeyboard.textView.selectedRange().location == 9,
      "Backspace deletes the preceding character without jumping paragraphs")

let wrapping = Editor()
let wrappedText = String(repeating: "A normal paragraph wraps at the edge of the writing column. ", count: 10)
wrapping.type(wrappedText)
var wrapsNormally = true
for width: CGFloat in [860, 520, 460] {
    wrapping.window.setContentSize(NSSize(width: width, height: 500))
    wrapping.window.contentView?.layoutSubtreeIfNeeded()
    let manager = wrapping.textView.textLayoutManager!
    manager.ensureLayout(for: manager.documentRange)
    var lineCount = 0
    manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout]) { fragment in
        lineCount += fragment.textLineFragments.count
        return true
    }
    wrapsNormally = wrapsNormally && lineCount > 1 && lineCount < 100 && wrapping.model.blocks.count == 1
        && wrapping.textView.textContainer!.containerSize.width >= width - 200
}
check(wrapsNormally, "long paragraphs wrap naturally at normal, narrow, and minimum window widths")
wrapping.snapshot("keyboard-wrapping-minimum-width")

// MARK: Writing and formatting a short essay

let essay = Editor()
essay.style(.title)
essay.type("On Writing Simply")
essay.enter()
check(essay.state.style == .body, "Return after a Title continues in Body")
pump()
check((essay.window as? EditorWindow)?.header?.documentTitle.stringValue.contains("Edited") == true,
      "typing marks the custom document header as edited")
essay.style(.subtitle)
essay.type("Notes toward a quieter editor")
essay.enter()
essay.type("Good tools disappear. When the page is calm, the ")
essay.textView.toggleItalic(nil)
essay.type("words")
essay.textView.toggleItalic(nil)
essay.type(" come forward and the ")
essay.textView.toggleBold(nil)
essay.type("structure")
essay.textView.toggleBold(nil)
essay.type(" does the rest.")
essay.enter()
essay.style(.heading)
essay.type("Three principles")
essay.enter()
essay.textView.toggleNumberedList(nil)
essay.type("Styles carry meaning, not just looks.")
essay.enter()
check(essay.state.list == .number, "Return in a list item continues the list")
essay.type("Every control earns its place.")
essay.enter()
essay.type("Files belong to the writer.")
essay.enter()
essay.enter()
check(essay.state.list == nil, "Return on an empty list item ends the list")
essay.style(.subheading)
essay.type("A few reminders")
essay.enter()
essay.textView.toggleBulletedList(nil)
essay.type("Write first, format later.")
essay.enter()
essay.type("Headings are for readers.")
essay.enter()
essay.enter()
essay.style(.quote)
essay.type("Never use two words when one will do.")
essay.enter()
check(essay.state.style == .quote, "Return in a Quote continues the Quote")
essay.style(.body)
essay.type("Ünïcödé, 日本語, עברית, and emoji 🎉 sit comfortably together.")

let written = essay.model
check(written.blocks.map(\.style) == [
    .title, .subtitle, .body, .heading, .body, .body, .body, .subheading, .body, .body, .quote, .body,
], "paragraph styles are as written")
check(written.blocks.map(\.list) == [nil, nil, nil, nil, .number, .number, .number, nil, .bullet, .bullet, nil, nil], "lists are as written")
check(written.blocks[2].runs == [
    Run(text: "Good tools disappear. When the page is calm, the "),
    Run(text: "words", italic: true),
    Run(text: " come forward and the "),
    Run(text: "structure", bold: true),
    Run(text: " does the rest."),
], "inline marks are as written")

let storage = essay.textView.textStorage!
let ns = storage.string as NSString
let ordinals = [4, 5, 6].map { index -> Int in
    var paragraph = 0, location = 0
    while paragraph < index { location = NSMaxRange(ns.paragraphRange(for: NSRange(location: location, length: 0))); paragraph += 1 }
    return storage.attribute(.hermesListOrdinal, at: location, effectiveRange: nil) as? Int ?? 0
}
check(ordinals == [1, 2, 3], "numbered items are numbered 1, 2, 3")
let titleFont = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
check(titleFont.pointSize >= 30, "title is set in display size")

// Link on a selection
let linkRange = ns.range(of: "calm")
essay.textView.setSelectedRange(linkRange)
essay.textView.applyLink(URL(string: "https://example.com/calm"), to: linkRange)
check(essay.model.blocks[2].runs.contains { $0.link == "https://example.com/calm" }, "links are kept in the model")
essay.moveToEnd()

// MARK: Appearance updates every paragraph

essay.document.editor!.setAppearance(.classic)
let classicTitle = storage.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
check(classicTitle.familyName == "Charter", "changing appearance restyles every paragraph")
essay.snapshot("editor-classic-light")
essay.document.editor!.setAppearance(.mono)
essay.snapshot("editor-mono-light")
essay.document.editor!.setAppearance(.sans)
essay.snapshot("editor-sans-light")
essay.document.editor!.setAppearance(.serif)
essay.window.appearance = NSAppearance(named: .aqua)
essay.snapshot("editor-serif-light")
essay.window.appearance = NSAppearance(named: .darkAqua)
essay.snapshot("editor-serif-dark")
essay.window.appearance = nil

// MARK: Save, close, reopen

let fileURL = outputDirectory.appendingPathComponent("Essay.hrms")
var saveError: Error?
var saved = false
essay.document.save(to: fileURL, ofType: "dev.hermes.hrms", for: .saveOperation) { error in
    saveError = error
    saved = true
}
while !saved { pump() }
check(saveError == nil, "document saves (\(saveError?.localizedDescription ?? "ok"))")
let reopened = try Document(contentsOf: fileURL, ofType: "dev.hermes.hrms")
let expected = try HermesCore.decodeFile(HermesCore.encodeFile(essay.model))
check(reopened.model == expected, "reopened document matches what was written")
check(reopened.model.appearance == .serif, "appearance is saved with the document")

// MARK: Export

let finalModel = essay.model
try Exporter.writePDF(for: finalModel, printInfo: essay.document.printInfo, to: outputDirectory.appendingPathComponent("Essay.pdf"))
try Exporter.rtfData(for: finalModel).write(to: outputDirectory.appendingPathComponent("Essay.rtf"))
try Exporter.plainTextData(for: finalModel).write(to: outputDirectory.appendingPathComponent("Essay.txt"))
let plain = try String(contentsOf: outputDirectory.appendingPathComponent("Essay.txt"), encoding: .utf8)
check(plain.contains("1. Styles carry meaning") && plain.contains("• Headings are for readers."), "plain text export includes list markers")

// MARK: Paste, copy and undo

let scratch = Editor()
let pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.hermes.harness.\(UUID().uuidString)"))
let foreign = NSMutableAttributedString(string: "Pasted ", attributes: [.font: NSFont(name: "Helvetica", size: 30)!, .foregroundColor: NSColor.red])
foreign.append(NSAttributedString(string: "rich", attributes: [.font: NSFont(name: "Helvetica-Bold", size: 30)!]))
foreign.append(NSAttributedString(string: " text\r\nSecond line", attributes: [.font: NSFont(name: "Helvetica", size: 9)!]))
pasteboard.clearContents()
pasteboard.writeObjects([foreign])
check(scratch.textView.readSelection(from: pasteboard, type: .rtf), "rich text paste is accepted")
check(scratch.model.blocks == [
    Block(runs: [Run(text: "Pasted "), Run(text: "rich", bold: true), Run(text: " text")]),
    Block(runs: [Run(text: "Second line")]),
], "pasted rich text keeps bold and drops foreign fonts and colors")
let pastedColor = scratch.textView.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
check(pastedColor == NSColor.textColor, "pasted text takes the document's color")

let headingRange = (storage.string as NSString).paragraphRange(for: NSRange(location: (storage.string as NSString).range(of: "Three principles").location, length: 0))
essay.textView.setSelectedRange(headingRange)
pasteboard.clearContents()
check(essay.textView.writeSelection(to: pasteboard, types: [.hermesFragment, .rtf, .string]), "copy writes a Hermes fragment")
scratch.moveToEnd()
scratch.enter()
check(scratch.textView.readSelection(from: pasteboard, type: .hermesFragment), "Hermes fragment paste is accepted")
let legacyPaste = NSPasteboard.withUniqueName()
legacyPaste.setData(pasteboard.data(forType: .hermesFragment)!, forType: .legacyWritingFragment)
let legacyPasteDestination = Editor()
check(legacyPasteDestination.textView.readSelection(from: legacyPaste, type: .legacyWritingFragment), "legacy clipboard fragments are accepted")
let modernPasteDestination = Editor()
_ = modernPasteDestination.textView.readSelection(from: pasteboard, type: .hermesFragment)
check(legacyPasteDestination.model.blocks == modernPasteDestination.model.blocks, "legacy clipboard preserves styled content")
check(scratch.model.blocks[2].style == .heading, "copy and paste between documents keeps paragraph styles")

scratch.textView.breakUndoCoalescing()
pump()
let wordRange = (scratch.textView.string as NSString).range(of: "Second line")
scratch.textView.setSelectedRange(wordRange)
scratch.textView.toggleBold(nil)
pump()
check(scratch.model.blocks[1].runs.first?.bold == true, "bold applies to a selection")
scratch.document.undoManager?.undo()
pump()
check(scratch.model.blocks[1].runs.first?.bold == false, "undo removes the bold")
check(scratch.document.isDocumentEdited, "edits mark the document as changed")

// MARK: App appearance and formatting panel layout

let appearanceSuite = "dev.hermes.harness.appearance.\(UUID().uuidString)"
let appearanceDefaults = UserDefaults(suiteName: appearanceSuite)!
let appAppearance = AppAppearanceController(defaults: appearanceDefaults)
let previousAppAppearance = NSApp.appearance
let modelBeforeAppearance = essay.model
check(appAppearance.selection == .system, "app appearance defaults to System")
for choice in [AppAppearance.light, .dark] {
    let menuItem = NSMenuItem()
    menuItem.tag = AppAppearance.allCases.firstIndex(of: choice)!
    appAppearance.changeAppearance(menuItem)
    pump()
    let expected: NSAppearance.Name = choice == .light ? .aqua : .darkAqua
    check([essay.window, scratch.window].allSatisfy {
        $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
    }, "\(choice.displayName) appearance updates all existing document windows")
    let newWindow = Editor()
    check(newWindow.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected,
          "new windows inherit \(choice.displayName) appearance")
    newWindow.window.orderOut(nil)
    check(AppAppearanceController(defaults: appearanceDefaults).selection == choice,
          "\(choice.displayName) appearance survives preference reload")
    _ = appAppearance.validateMenuItem(menuItem)
    check(menuItem.state == .on, "\(choice.displayName) appearance is checked in the menu")
}
appAppearance.select(.system)
check(NSApp.appearance == nil, "System appearance removes the app override")
check(essay.model == modelBeforeAppearance, "app appearance leaves document content and typography unchanged")
NSApp.appearance = previousAppAppearance
appearanceDefaults.removePersistentDomain(forName: appearanceSuite)

func descendants(of view: NSView) -> [NSView] {
    view.subviews.flatMap { [$0] + descendants(of: $0) }
}

let formatPanel = FormatPanelController(editor: essay.document.editor!)
_ = formatPanel.view
let panelWindow = NSWindow(contentRect: NSRect(origin: .zero, size: formatPanel.preferredContentSize),
                           styleMask: [.borderless], backing: .buffered, defer: false)
panelWindow.contentViewController = formatPanel
panelWindow.setFrameOrigin(NSPoint(x: -4000, y: -4000))
panelWindow.orderFront(nil)
for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
    panelWindow.appearance = NSAppearance(named: appearance)
    formatPanel.viewWillAppear()
    pump()
    let content = formatPanel.view
    content.layoutSubtreeIfNeeded()
    let controls = descendants(of: content).compactMap { $0 as? NSControl }
    check(controls.allSatisfy {
        let rect = $0.convert($0.bounds, to: content)
        return rect.minX >= 16 && rect.maxX <= content.bounds.width - 16
            && rect.minY >= 16 && rect.maxY <= content.bounds.height - 16
    }, "\(name) formatting panel keeps every control inside its margins")
    let popups = controls.compactMap { $0 as? NSPopUpButton }
    check(popups.count == 2 && abs(popups[0].convert(.zero, to: content).x - popups[1].convert(.zero, to: content).x) < 1
          && abs(popups[0].frame.width - popups[1].frame.width) < 1,
          "\(name) typeface and appearance dropdowns align")
    let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds)!
    content.cacheDisplay(in: content.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: outputDirectory.appendingPathComponent("format-panel-\(name).png"))
}
panelWindow.orderOut(nil)

// MARK: Text size and paragraph alignment

let styled = Editor()
let originalStyles = DocumentModel(blocks: [
    Block(alignment: .center, lineHeight: 2, runs: [
        Run(text: "Marked words", bold: true, italic: true, underline: true,
            link: "https://example.com/", fontSize: 20, letterSpacing: 1.2),
        Run(text: " and plain", fontSize: 30),
    ]),
    Block(runs: [Run(text: "Another paragraph")]),
])
styled.document.editor!.load(originalStyles)
styled.document.undoManager?.removeAllActions()
styled.textView.setSelectedRange(NSRange(location: 2, length: 4))
styled.style(.heading)
pump()
let appliedHeading = styled.model.blocks[0]
check(appliedHeading.style == .heading && appliedHeading.runs.allSatisfy { $0.fontSize == nil }
      && appliedHeading.lineHeight == nil && styled.model.blocks[1] == originalStyles.blocks[1],
      "choosing a style applies its size and spacing to the whole touched paragraph only")
check(appliedHeading.runs.first == Run(text: "Marked words", bold: true, italic: true, underline: true,
                                     link: "https://example.com/", letterSpacing: 1.2)
      && appliedHeading.alignment == .center,
      "applying a style preserves emphasis, links, alignment and explicit letter spacing")
check(styled.textView.selectedRange() == NSRange(location: 2, length: 4),
      "applying a paragraph style preserves the text selection")
styled.document.undoManager?.undo()
pump()
check(styled.model == originalStyles, "one Undo restores the paragraph style and every formatting override")
styled.document.undoManager?.redo()
pump()
check(styled.model.blocks[0] == appliedHeading, "Redo reapplies the complete paragraph style change")
styled.textView.setSelectedRange(NSRange(location: 0, length: styled.textView.string.utf16.count))
pump()
check(styled.state.hasMixedStyles, "selecting different paragraph styles reports Mixed Styles")
let styleControl = (styled.window as! EditorWindow).header!.subviews.compactMap { $0 as? NSPopUpButton }.first!
check(styleControl.titleOfSelectedItem == "Mixed Styles" && styleControl.selectedTag() == -1,
      "the header displays Mixed Styles for a mixed selection")
let headingMenuItem = NSMenuItem()
headingMenuItem.action = #selector(EditorTextView.applyParagraphStyle(_:))
headingMenuItem.tag = ParagraphStyle.allCases.firstIndex(of: .heading)!
_ = styled.textView.validateMenuItem(headingMenuItem)
check(headingMenuItem.state == .off, "mixed styles do not check a misleading menu item")
styled.style(.subheading)
pump()
check(styled.model.blocks.allSatisfy { $0.style == .subheading } && !styled.state.hasMixedStyles
      && styleControl.titleOfSelectedItem == "Subheading",
      "choosing a style resolves a mixed selection and updates the header")
styled.document.undoManager?.undo()
pump()
check(styled.model.blocks.map(\.style) == [.heading, .body], "Undo restores the different paragraph styles")
check(styleControl.titleOfSelectedItem == (styled.state.hasMixedStyles ? "Mixed Styles" : styled.state.style.displayName),
      "the header matches the selection restored by native Undo")
styled.textView.setSelectedRange(NSRange(location: 0, length: styled.textView.string.utf16.count))
pump()
check(styled.state.hasMixedStyles && styleControl.titleOfSelectedItem == "Mixed Styles",
      "the header reflects mixed styles after Undo and reselection")

for headingStyle in [ParagraphStyle.title, .subtitle, .heading, .subheading] {
    let continuation = Editor()
    continuation.document.editor!.load(DocumentModel(blocks: [
        Block(style: headingStyle, lineHeight: 2, runs: [
            Run(text: "Heading", bold: true, italic: true, underline: true,
                link: "https://example.com/", fontSize: 40, letterSpacing: 2),
        ]),
    ]))
    continuation.moveToEnd()
    continuation.enter()
    continuation.type("Body")
    check(continuation.model.blocks.last == Block(runs: [Run(text: "Body")])
          && continuation.state.fontSize == 16 && continuation.state.effectiveLineHeight == 1.4,
          "Return after \(headingStyle.displayName) starts clean 16 pt Body text")
    continuation.window.orderOut(nil)
}
let emptyStyled = Editor()
emptyStyled.textView.setFontSize(40)
emptyStyled.textView.setLineHeight(2)
emptyStyled.style(.heading)
emptyStyled.type("New heading")
check(emptyStyled.state.fontSize == 24 && emptyStyled.model.blocks[0].lineHeight == nil,
      "choosing a style in an empty document clears typing size and line height overrides")
emptyStyled.window.orderOut(nil)
styled.window.orderOut(nil)

let formatted = Editor()
formatted.type("Small and large")
formatted.enter()
formatted.type("Another paragraph")
formatted.textView.breakUndoCoalescing()
pump()
formatted.textView.setSelectedRange(NSRange(location: 10, length: 5))
formatted.textView.setFontSize(36)
pump()
check(formatted.model.blocks[0].runs == [Run(text: "Small and "), Run(text: "large", fontSize: 36)],
      "text size changes only the selected text")
formatted.document.undoManager?.undo()
pump()
check(formatted.model.blocks[0].runs.allSatisfy { $0.fontSize == nil }, "undo restores the previous text size")
formatted.document.undoManager?.redo()
pump()
check(formatted.model.blocks[0].runs.last?.fontSize == 36, "redo restores the custom text size")
formatted.textView.setSelectedRange(NSRange(location: 0, length: 15))
check(formatted.state.fontSize == nil, "a selection with different text sizes reports Mixed")
formatted.textView.alignCenter(nil)
check(formatted.model.blocks[0].alignment == .center && formatted.model.blocks[1].alignment == .left,
      "alignment applies to selected paragraphs only")
formatted.textView.setSelectedRange(NSRange(location: 0, length: formatted.textView.string.utf16.count))
formatted.textView.alignRight(nil)
check(formatted.model.blocks.allSatisfy { $0.alignment == .right }, "alignment applies across multiple selected paragraphs")
formatted.textView.breakUndoCoalescing()
pump()
formatted.textView.alignLeft(nil)
pump()
formatted.document.undoManager?.undo()
pump()
check(formatted.model.blocks.allSatisfy { $0.alignment == .right }, "undo restores paragraph alignment")
formatted.moveToEnd()
formatted.textView.setFontSize(23)
formatted.type(" custom")
formatted.enter()
formatted.type("Continued")
check(formatted.model.blocks.last?.runs.first?.fontSize == 23 && formatted.model.blocks.last?.alignment == .right,
      "new typing and Return preserve size and alignment")
formatted.document.editor!.setAppearance(.mono)
check(formatted.model.blocks[0].runs.last?.fontSize == 36, "changing typeface preserves explicit text sizes")
let formattedURL = outputDirectory.appendingPathComponent("Formatted.hrms")
try formatted.document.data(ofType: "dev.hermes.hrms").write(to: formattedURL)
let formattedReopened = try Document(contentsOf: formattedURL, ofType: "dev.hermes.hrms")
let expectedFormatted = try HermesCore.decodeFile(HermesCore.encodeFile(formatted.model))
check(formattedReopened.model == expectedFormatted,
      "save and reopen keep custom sizes and paragraph alignment")
try Exporter.writePDF(for: formatted.model, printInfo: formatted.document.printInfo, to: outputDirectory.appendingPathComponent("Formatted.pdf"))
formatted.snapshot("editor-size-alignment")

let controlsPanel = FormatPanelController(editor: formatted.document.editor!)
_ = controlsPanel.view
controlsPanel.view.frame.size = controlsPanel.preferredContentSize
controlsPanel.viewWillAppear()
let sizeControl = descendants(of: controlsPanel.view).compactMap { $0 as? NumericStepperControl }.first!
let sizeField = sizeControl.field
check(!sizeField.stringValue.isEmpty, "the size field displays the current point size immediately")
sizeField.stringValue = "27"
_ = NSApp.sendAction(sizeField.action!, to: sizeField.target, from: sizeField)
formatted.type(" sized")
check(formatted.model.blocks.last?.runs.last?.fontSize == 27, "the size control accepts a custom point size")
sizeControl.stepper.doubleValue += sizeControl.stepper.increment
_ = NSApp.sendAction(sizeControl.stepper.action!, to: sizeControl.stepper.target, from: sizeControl.stepper)
formatted.type(" larger")
check(formatted.model.blocks.last?.runs.last?.fontSize == 28 && sizeField.stringValue == "28", "the size up arrow adds one point and updates its value")
sizeControl.stepper.doubleValue -= sizeControl.stepper.increment
_ = NSApp.sendAction(sizeControl.stepper.action!, to: sizeControl.stepper.target, from: sizeControl.stepper)
check(formatted.state.fontSize == 27, "the size down arrow subtracts one point")
sizeField.stringValue = "27.5"
_ = NSApp.sendAction(sizeField.action!, to: sizeField.target, from: sizeField)
check(formatted.state.fontSize == 27 && sizeField.stringValue == "27", "fractional point sizes are rejected and the visible value is restored")
sizeField.stringValue = "Style Default"
_ = NSApp.sendAction(sizeField.action!, to: sizeField.target, from: sizeField)
formatted.type(" default")
check(formatted.model.blocks.last?.runs.last?.fontSize == nil, "Style Default restores style-based text size")
check(sizeField.stringValue == String(formatted.state.fontSize!), "restoring size defaults still displays a numeric value")
check(sizeControl.stepper.minValue == 8 && sizeControl.stepper.maxValue == 144 && !sizeControl.stepper.valueWraps,
      "size arrows are bounded from 8 to 144 without wrapping")
let beforeInvalidSize = formatted.model
formatted.textView.setFontSize(500)
check(formatted.model == beforeInvalidSize, "invalid text sizes leave the document unchanged")
let alignmentControl = descendants(of: controlsPanel.view).compactMap { $0 as? NSSegmentedControl }
    .first { $0.segmentCount == 3 && $0.toolTip(forSegment: 0) == "Align Left" }!
alignmentControl.selectedSegment = 1
_ = NSApp.sendAction(alignmentControl.action!, to: alignmentControl.target, from: alignmentControl)
check(formatted.model.blocks.last?.alignment == .center, "the alignment control centers the current paragraph")

formatted.textView.setSelectedRange(NSRange(location: 0, length: formatted.textView.string.utf16.count))
pasteboard.clearContents()
_ = formatted.textView.writeSelection(to: pasteboard, types: [.hermesFragment])
let fragmentDestination = Editor()
_ = fragmentDestination.textView.readSelection(from: pasteboard, type: .hermesFragment)
check(fragmentDestination.model.blocks == formatted.model.blocks, "Hermes copy and paste preserve size and alignment")

// MARK: Letter spacing

let tracked = Editor()
tracked.type("Normal wide text")
tracked.textView.setSelectedRange(NSRange(location: 7, length: 4))
tracked.textView.breakUndoCoalescing()
pump()
tracked.textView.setLetterSpacing(1.5)
pump()
check(tracked.model.blocks[0].runs == [Run(text: "Normal "), Run(text: "wide", letterSpacing: 1.5), Run(text: " text")],
      "letter spacing changes only the selected text")
tracked.document.undoManager?.undo()
pump()
check(tracked.model.blocks[0].runs.allSatisfy { $0.letterSpacing == nil }, "undo restores normal letter spacing")
tracked.document.undoManager?.redo()
pump()
check(tracked.model.blocks[0].runs.contains { $0.letterSpacing == 1.5 }, "redo restores custom letter spacing")
tracked.textView.setSelectedRange(NSRange(location: 0, length: tracked.textView.string.utf16.count))
check(tracked.state.letterSpacing == nil, "mixed letter spacing is reported as Mixed")
let trackingPanel = FormatPanelController(editor: tracked.document.editor!)
_ = trackingPanel.view
trackingPanel.viewWillAppear()
let trackingControl = descendants(of: trackingPanel.view).compactMap { $0 as? NumericStepperControl }
    .first { $0.field.accessibilityLabel() == "Letter Spacing in Points" }!
check(trackingControl.field.stringValue.isEmpty, "the letter spacing field shows Mixed for a mixed selection")
trackingControl.field.stringValue = "2 pt"
_ = NSApp.sendAction(trackingControl.field.action!, to: trackingControl.field.target, from: trackingControl.field)
trackingControl.stepper.doubleValue += trackingControl.stepper.increment
_ = NSApp.sendAction(trackingControl.stepper.action!, to: trackingControl.stepper.target, from: trackingControl.stepper)
check(tracked.state.letterSpacing == 2.1 && trackingControl.field.stringValue == "2.1 pt",
      "the letter spacing field accepts points and its up arrow adds a tenth")
trackingControl.stepper.doubleValue -= trackingControl.stepper.increment
_ = NSApp.sendAction(trackingControl.stepper.action!, to: trackingControl.stepper.target, from: trackingControl.stepper)
check(tracked.state.letterSpacing == 2, "the letter spacing down arrow subtracts a tenth")
tracked.moveToEnd()
tracked.type(" more")
tracked.enter()
tracked.type("New paragraph")
check(tracked.model.blocks.allSatisfy { $0.runs.allSatisfy { $0.letterSpacing == 2 } },
      "letter spacing continues into new typing and after Return")
let trackingURL = outputDirectory.appendingPathComponent("LetterSpacing.hrms")
try tracked.document.data(ofType: "dev.hermes.hrms").write(to: trackingURL)
let trackingReopened = try Document(contentsOf: trackingURL, ofType: "dev.hermes.hrms")
check(trackingReopened.model == tracked.model, "saving and reopening preserves letter spacing")
try Exporter.writePDF(for: tracked.model, printInfo: tracked.document.printInfo,
                      to: outputDirectory.appendingPathComponent("LetterSpacing.pdf"))
tracked.textView.setSelectedRange(NSRange(location: 0, length: tracked.textView.string.utf16.count))
tracked.textView.setLetterSpacing(0)
check(tracked.state.letterSpacing == 0 && tracked.model.blocks.allSatisfy { $0.runs.allSatisfy { $0.letterSpacing == nil } },
      "zero restores natural letter spacing")
tracked.textView.setLetterSpacing(-0.5)
check(tracked.state.letterSpacing == -0.5, "negative values tighten letter spacing")
tracked.textView.setLetterSpacing(21)
check(tracked.state.letterSpacing == -0.5, "invalid letter spacing leaves the document unchanged")
tracked.snapshot("editor-letter-spacing")

// MARK: Line height

let spaced = Editor()
spaced.textView.setLineHeight(1.5)
spaced.type(String(repeating: "Text with a little more breathing room. ", count: 8))
spaced.enter()
spaced.type("Another paragraph")
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.5 }, "line height applies to typing and continues after Return")
spaced.textView.setSelectedRange(NSRange(location: 0, length: 2))
spaced.textView.breakUndoCoalescing()
pump()
spaced.textView.setLineHeight(2)
pump()
check(spaced.model.blocks[0].lineHeight == 2 && spaced.model.blocks[1].lineHeight == 1.5,
      "line height applies to the entire current paragraph only")
spaced.document.undoManager?.undo()
pump()
check(spaced.model.blocks[0].lineHeight == 1.5, "undo restores line height")
spaced.document.undoManager?.redo()
pump()
check(spaced.model.blocks[0].lineHeight == 2, "redo restores line height")
spaced.textView.setSelectedRange(NSRange(location: 0, length: spaced.textView.string.utf16.count))
check(spaced.state.hasMixedLineHeight, "different paragraph line heights report Mixed")
let spacingPanel = FormatPanelController(editor: spaced.document.editor!)
_ = spacingPanel.view
spacingPanel.viewWillAppear()
let spacingControl = descendants(of: spacingPanel.view).compactMap { $0 as? NumericStepperControl }.last!
let spacingField = spacingControl.field
check(spacingField.stringValue.isEmpty && spacingField.placeholderString == "Mixed", "line height control shows Mixed for mixed selections")
spacingField.stringValue = "1.8"
_ = NSApp.sendAction(spacingField.action!, to: spacingField.target, from: spacingField)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.8 }, "custom line height applies to all selected paragraphs")
spacingControl.stepper.doubleValue += spacingControl.stepper.increment
_ = NSApp.sendAction(spacingControl.stepper.action!, to: spacingControl.stepper.target, from: spacingControl.stepper)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.9 } && spacingField.stringValue == "1.9×", "the line height up arrow adds a tenth without floating point artifacts")
spacingControl.stepper.doubleValue -= spacingControl.stepper.increment
_ = NSApp.sendAction(spacingControl.stepper.action!, to: spacingControl.stepper.target, from: spacingControl.stepper)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.8 }, "the line height down arrow subtracts a tenth")
spacingField.stringValue = "2garbage"
_ = NSApp.sendAction(spacingField.action!, to: spacingField.target, from: spacingField)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.8 } && spacingField.stringValue == "1.8×", "invalid spacing restores the previous visible value")
spacingField.stringValue = "Style Default"
_ = NSApp.sendAction(spacingField.action!, to: spacingField.target, from: spacingField)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == nil }, "Style Default removes custom line height")
check(spacingField.stringValue == "1.4×", "default line height displays the actual style multiplier")
check(spacingControl.stepper.minValue == 1 && spacingControl.stepper.maxValue == 3 && !spacingControl.stepper.valueWraps,
      "line height arrows are bounded from 1 to 3 without wrapping")
spaced.textView.setLineHeight(1.75)
let beforeInvalidHeight = spaced.model
for height in [0.5, 4, Double.nan, Double.infinity] { spaced.textView.setLineHeight(height) }
check(spaced.model == beforeInvalidHeight, "invalid line heights leave the document unchanged")
spaced.document.editor!.setAppearance(.mono)
check(spaced.model.blocks.allSatisfy { $0.lineHeight == 1.75 }, "changing typeface preserves custom line height")
let spacingURL = outputDirectory.appendingPathComponent("LineHeight.hrms")
try spaced.document.data(ofType: "dev.hermes.hrms").write(to: spacingURL)
let spacingReopened = try Document(contentsOf: spacingURL, ofType: "dev.hermes.hrms")
check(spacingReopened.model == spaced.model, "save and reopen preserve custom line height")
pasteboard.clearContents()
_ = spaced.textView.writeSelection(to: pasteboard, types: [.hermesFragment])
let spacingDestination = Editor()
_ = spacingDestination.textView.readSelection(from: pasteboard, type: .hermesFragment)
check(spacingDestination.model.blocks == spaced.model.blocks, "Hermes copy and paste preserve line height")
spacingDestination.moveToEnd()
pasteboard.clearContents()
pasteboard.setString("\nPasted line", forType: .string)
_ = spacingDestination.textView.readSelection(from: pasteboard, type: .string)
check(spacingDestination.model.blocks.last?.lineHeight == 1.75, "plain text paste takes the destination line height")
try Exporter.writePDF(for: spaced.model, printInfo: spaced.document.printInfo, to: outputDirectory.appendingPathComponent("LineHeight.pdf"))
spaced.snapshot("editor-line-height")

// MARK: Interactive edge cases (links, lists, rename validation)

let edge = Editor()
edge.textView.applyLink(URL(string: "https://example.com/direct"), to: NSRange(location: 0, length: 0))
check(edge.textView.string == "https://example.com/direct"
      && edge.model.blocks[0].runs.first?.link == "https://example.com/direct",
      "applying a link to an empty selection inserts the linked URL")
edge.textView.applyLink(nil, to: NSRange(location: 0, length: edge.textView.string.utf16.count))
check(edge.model.blocks[0].runs.first?.link == nil, "removing a link clears it from the model while keeping text")

let listEdge = Editor()
listEdge.textView.toggleBulletedList(nil)
listEdge.type("First second")
listEdge.textView.setSelectedRange(NSRange(location: 5, length: 0))
listEdge.enter()
check(listEdge.model.blocks.count == 2 && listEdge.model.blocks.allSatisfy { $0.list == .bullet },
      "Return in the middle of a list item splits it into two list items")
listEdge.textView.setSelectedRange(NSRange(location: 0, length: listEdge.textView.string.utf16.count))
listEdge.textView.toggleNumberedList(nil)
check(listEdge.model.blocks.allSatisfy { $0.list == .number },
      "switching a bulleted list directly to numbered updates every selected item")

let invalidNames = ["", "   ", ".", "..", "a/b", "a:b"]
var rejectedInvalidNames = true
for bad in invalidNames {
    var gotError: Error?
    edge.document.rename(to: bad) { gotError = $0 }
    if (gotError as NSError?)?.code != NSFileWriteInvalidFileNameError { rejectedInvalidNames = false }
}
check(rejectedInvalidNames, "rename rejects empty, dot, slash and colon filenames")
edge.window.orderOut(nil)
listEdge.window.orderOut(nil)

// MARK: Code, strikethrough and Smart Markdown typing

let smart = Editor()
smart.textView.smartMarkdownEnabledOverride = true
func typeChars(_ editor: Editor, _ s: String) {
    for ch in s {
        if ch == "\n" {
            editor.enter()
        } else {
            editor.textView.insertText(String(ch), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        pump(0.002)
    }
}

typeChars(smart, "# Smart Title\n")
typeChars(smart, "## Section\n")
typeChars(smart, "### Sub\n")
typeChars(smart, "> Quoted\n")
smart.style(.body)
typeChars(smart, "- First bullet\nSecond bullet\n\n")
typeChars(smart, "1. First num\nSecond num\n\n")
typeChars(smart, "Hello **bold** and *italic* and _em_ and __strong__ and ~~old~~ and `code` tail.")
check(smart.model.blocks.map(\.style) == [.title, .heading, .subheading, .quote, .body, .body, .body, .body, .body],
      "Smart Markdown block triggers create Title, Heading, Subheading, Quote, and lists")
check(smart.model.blocks.map(\.list) == [nil, nil, nil, nil, .bullet, .bullet, .number, .number, nil],
      "Smart Markdown list triggers create bulleted and numbered lists")
check(smart.model.blocks.last?.runs == [
    Run(text: "Hello "),
    Run(text: "bold", bold: true),
    Run(text: " and "),
    Run(text: "italic", italic: true),
    Run(text: " and "),
    Run(text: "em", italic: true),
    Run(text: " and "),
    Run(text: "strong", bold: true),
    Run(text: " and "),
    Run(text: "old", strikethrough: true),
    Run(text: " and "),
    Run(text: "code", code: true),
    Run(text: " tail."),
], "Smart Markdown inline triggers convert marks cleanly and reset typing attributes afterward")

// Nested inline marks, anti-false-positives, and code immunity
let smartEdge = Editor()
smartEdge.textView.smartMarkdownEnabledOverride = true
typeChars(smartEdge, "**a *b* c** and snake_case_name and 2 * 3 * 4")
check(smartEdge.model.blocks[0].runs == [
    Run(text: "a ", bold: true),
    Run(text: "b", bold: true, italic: true),
    Run(text: " c", bold: true),
    Run(text: " and snake_case_name and 2 * 3 * 4"),
], "Smart Markdown preserves nested marks and ignores intraword underscores and spaced asterisks")

// Inside inline code, `*x*` must stay literal
let codeImmune = Editor()
codeImmune.textView.smartMarkdownEnabledOverride = true
codeImmune.textView.toggleCode(nil)
typeChars(codeImmune, "ptr *x*")
check(codeImmune.model.blocks[0].runs == [Run(text: "ptr *x*", code: true)],
      "inline Markdown triggers do not fire inside existing inline code")

// Undo of inline trigger restores literal delimiters; Redo reapplies formatting
let smartUndo = Editor()
smartUndo.textView.smartMarkdownEnabledOverride = true
typeChars(smartUndo, "keep **bold**")
pump()
check(smartUndo.model.blocks[0].runs == [Run(text: "keep "), Run(text: "bold", bold: true)],
      "inline Smart Markdown converts typed delimiters")
smartUndo.document.undoManager?.undo()
pump()
check(smartUndo.textView.string == "keep **bold**" && smartUndo.model.blocks[0].runs.allSatisfy { !$0.bold },
      "single Undo after inline Smart Markdown restores literal delimiters")
smartUndo.document.undoManager?.redo()
pump()
check(smartUndo.model.blocks[0].runs == [Run(text: "keep "), Run(text: "bold", bold: true)],
      "Redo reapplies the inline Smart Markdown conversion")

// Undo of block trigger on existing text restores literal prefix and Body style in one step
let blockUndo = Editor()
blockUndo.textView.smartMarkdownEnabledOverride = true
blockUndo.type("Existing")
blockUndo.textView.breakUndoCoalescing()
pump()
blockUndo.textView.setSelectedRange(NSRange(location: 0, length: 0))
typeChars(blockUndo, "## ")
pump()
check(blockUndo.textView.string == "Existing" && blockUndo.model.blocks[0].style == .heading,
      "Smart Markdown block trigger converts an existing paragraph to Heading")
blockUndo.document.undoManager?.undo()
pump()
check(blockUndo.textView.string == "## Existing" && blockUndo.model.blocks[0].style == .body,
      "single Undo after block Smart Markdown restores the literal prefix and original style")

// Disabling Smart Markdown keeps literal syntax intact
let smartOff = Editor()
smartOff.textView.smartMarkdownEnabledOverride = false
typeChars(smartOff, "# Literal **text**")
check(smartOff.textView.string == "# Literal **text**" && smartOff.model.blocks[0].style == .body
      && smartOff.model.blocks[0].runs.allSatisfy { !$0.bold },
      "disabling Smart Markdown leaves typed Markdown syntax literal")

// Format panel segments 3 & 4 toggle Strikethrough and Inline Code, and v5 save/reopen preserves them
let markPanelEditor = Editor()
markPanelEditor.type("strike code")
let markPanel = FormatPanelController(editor: markPanelEditor.document.editor!)
_ = markPanel.view
markPanel.viewWillAppear()
let markSegments = descendants(of: markPanel.view).compactMap { $0 as? NSSegmentedControl }.first { $0.segmentCount == 5 }!
markPanelEditor.textView.setSelectedRange(NSRange(location: 0, length: 6))
markSegments.selectedSegment = 3
_ = NSApp.sendAction(markSegments.action!, to: markSegments.target, from: markSegments)
markPanelEditor.textView.setSelectedRange(NSRange(location: 7, length: 4))
markSegments.selectedSegment = 4
_ = NSApp.sendAction(markSegments.action!, to: markSegments.target, from: markSegments)
check(markPanelEditor.model.blocks[0].runs == [
    Run(text: "strike", strikethrough: true),
    Run(text: " "),
    Run(text: "code", code: true),
], "Format panel toggles Strikethrough and Inline Code on selections")
let v5URL = outputDirectory.appendingPathComponent("V5Marks.hrms")
try markPanelEditor.document.data(ofType: "dev.hermes.hrms").write(to: v5URL)
let v5Reopened = try Document(contentsOf: v5URL, ofType: "dev.hermes.hrms")
check(v5Reopened.model == markPanelEditor.model, "v5 save and reopen preserves code and strikethrough")

// Return after Heading with code/strikethrough starts clean Body
let headingReset = Editor()
headingReset.document.editor!.load(DocumentModel(blocks: [
    Block(style: .heading, runs: [Run(text: "CodeHead", strikethrough: true, code: true)]),
]))
headingReset.moveToEnd()
headingReset.enter()
headingReset.type("Clean")
check(headingReset.model.blocks.last == Block(runs: [Run(text: "Clean")]),
      "Return after a Heading clears inline code and strikethrough")

for editor in [smart, smartEdge, codeImmune, smartUndo, blockUndo, smartOff, markPanelEditor, headingReset] {
    editor.window.orderOut(nil)
}

// MARK: Long document performance

let longModel = DocumentModel(blocks: (0..<4000).map { i in
    Block(style: i % 40 == 0 ? .heading : .body, list: i % 40 == 5 ? .bullet : nil, runs: [
        Run(text: "Paragraph \(i). The quick brown fox jumps over the lazy dog, and then "),
        Run(text: "keeps running", italic: true),
        Run(text: " across the long and winding field until the evening light fades away."),
    ])
})
let long = Editor()
var start = Date()
long.document.editor!.load(longModel)
pump()
let loadTime = Date().timeIntervalSince(start)
long.textView.setSelectedRange(NSRange(location: 0, length: 0))
start = Date()
for _ in 0..<50 { long.type("x") }
long.textView.textLayoutManager!.ensureLayout(for: long.textView.textLayoutManager!.textViewportLayoutController.viewportRange ?? long.textView.textLayoutManager!.documentRange)
let typingTime = Date().timeIntervalSince(start) / 50
start = Date()
long.textView.selectAll(nil)
_ = long.textView.formattingState
let selectAllTime = Date().timeIntervalSince(start)
start = Date()
let longData = try HermesCore.encodeFile(long.model)
let saveTime = Date().timeIntervalSince(start)
start = Date()
_ = try HermesCore.decodeFile(longData)
let decodeTime = Date().timeIntervalSince(start)
let words = HermesCore.wordCount(long.textView.string)
print(String(format: "  long document: %d words, load %.0f ms, per keystroke %.2f ms, selectAll+state %.1f ms, snapshot+encode %.0f ms, decode %.1f ms (%d KB)",
             words, loadTime * 1000, typingTime * 1000, selectAllTime * 1000, saveTime * 1000, decodeTime * 1000, longData.count / 1024))
check(typingTime < 0.008, "typing in a \(words)-word document stays under 8 ms per keystroke")
check(loadTime < 1.0, "loading a \(words)-word document stays under 1 s")
check(saveTime < 0.5, "snapshotting and encoding a \(words)-word document stays under 500 ms")

// MARK: Software update menu & settings

MainActor.assumeIsolated {
    let appMenu = NSApp.mainMenu?.items.first?.submenu
    let checkUpdatesItem = appMenu?.items.first { $0.action == #selector(UpdateController.checkForUpdates(_:)) }
    let autoUpdatesItem = appMenu?.items.first { $0.action == #selector(UpdateController.toggleAutomaticUpdateChecks(_:)) }
    check(checkUpdatesItem != nil && checkUpdatesItem?.target === UpdateController.shared,
          "app menu exposes Check for Updates… wired to UpdateController")
    check(autoUpdatesItem != nil && autoUpdatesItem?.target === UpdateController.shared,
          "app menu exposes Automatically Check for Updates wired to UpdateController")
    let isolatedDefaults = UserDefaults(suiteName: "dev.hermes.test.updates.\(UUID().uuidString)")!
    let testUpdater = UpdateController(defaults: isolatedDefaults)
    check(testUpdater.repository == "ninthdensity/hermes", "UpdateController reads HermesGitHubRepo from Info.plist")
    check(testUpdater.currentVersion == SemanticVersion(major: 0, minor: 1, patch: 0), "UpdateController reads current version from Info.plist")
    check(testUpdater.automaticallyChecksForUpdates == true, "automatic update checks default to enabled")
    if let autoItem = autoUpdatesItem {
        _ = testUpdater.validateMenuItem(autoItem)
        check(autoItem.state == .on, "Automatically Check for Updates menu item shows checkmark when enabled")
        testUpdater.toggleAutomaticUpdateChecks(autoItem)
        _ = testUpdater.validateMenuItem(autoItem)
        check(testUpdater.automaticallyChecksForUpdates == false && autoItem.state == .off,
              "toggling Automatically Check for Updates updates state and menu checkmark")
    }
}

print(failures == 0 ? "All harness checks passed." : "\(failures) harness check(s) failed.")
exit(failures == 0 ? 0 : 1)
