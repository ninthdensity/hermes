import AppKit
import HermesKit

public enum HermesApplication {
    public static func run() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        if defaults.string(forKey: "appAppearance") == nil,
           let appearance = defaults.persistentDomain(forName: "dev.quire.Quire")?["appAppearance"] as? String {
            defaults.set(appearance, forKey: "appAppearance")
        }
        AppAppearanceController.shared.apply()
        NSApp.mainMenu = MainMenu.build()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UpdateController.shared.scheduleAutomaticCheckIfNeeded()
    }

    @objc func showAbout(_ sender: Any?) {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "hermes",
        ]
        if let url = Bundle.main.url(forResource: "Logo", withExtension: "png"),
           let logo = NSImage(contentsOf: url) {
            logo.size = NSSize(width: 320, height: 320 * logo.size.height / logo.size.width)
            options[.applicationIcon] = logo
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(formatMenu()))
        main.addItem(submenu(viewMenu()))
        let window = windowMenu()
        main.addItem(submenu(window))
        NSApp.windowsMenu = window
        let help = NSMenu(title: "Help")
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func appMenu() -> NSMenu {
        let name = ProcessInfo.processInfo.processName
        let menu = NSMenu(title: name)
        menu.addItem(item("About \(name)", #selector(AppDelegate.showAbout(_:))))
        let checkUpdates = item("Check for Updates…", #selector(UpdateController.checkForUpdates(_:)))
        let autoUpdates = item("Automatically Check for Updates", #selector(UpdateController.toggleAutomaticUpdateChecks(_:)))
        MainActor.assumeIsolated {
            checkUpdates.target = UpdateController.shared
            autoUpdates.target = UpdateController.shared
        }
        menu.addItem(checkUpdates)
        menu.addItem(autoUpdates)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(item("Hide \(name)", #selector(NSApplication.hide(_:)), "h"))
        menu.addItem(item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        menu.addItem(item("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit \(name)", #selector(NSApplication.terminate(_:)), "q"))
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: "File")
        menu.addItem(item("New", #selector(NSDocumentController.newDocument(_:)), "n"))
        menu.addItem(item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"))
        menu.addItem(.separator())
        menu.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        menu.addItem(item("Save…", #selector(NSDocument.save(_:)), "s"))
        menu.addItem(item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]))
        menu.addItem(item("Rename…", #selector(NSDocument.rename(_:))))
        menu.addItem(item("Move To…", #selector(NSDocument.move(_:))))
        let revert = NSMenu(title: "Revert To")
        revert.addItem(item("Last Saved Version", #selector(NSDocument.revertToSaved(_:))))
        revert.addItem(item("Browse All Versions…", #selector(NSDocument.browseVersions(_:))))
        menu.addItem(submenu(revert))
        menu.addItem(.separator())
        let export = NSMenu(title: "Export To")
        export.addItem(item("PDF…", #selector(Document.exportPDF(_:))))
        export.addItem(item("Rich Text…", #selector(Document.exportRichText(_:))))
        export.addItem(item("Plain Text…", #selector(Document.exportPlainText(_:))))
        export.addItem(item("Markdown…", #selector(Document.exportMarkdown(_:))))
        export.addItem(item("Hermes Document…", #selector(Document.exportHermes(_:))))
        menu.addItem(submenu(export))
        menu.addItem(.separator())
        menu.addItem(item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]))
        menu.addItem(item("Print…", #selector(NSDocument.printDocument(_:)), "p"))
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(item("Undo", Selector(("undo:")), "z"))
        menu.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        menu.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        menu.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        menu.addItem(item("Paste and Match Style", #selector(NSTextView.pasteAsPlainText(_:)), "v", [.command, .option, .shift]))
        menu.addItem(item("Delete", #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(finder("Find…", .showFindInterface, "f"))
        find.addItem(finder("Find and Replace…", .showReplaceInterface, "f", [.command, .option]))
        find.addItem(finder("Find Next", .nextMatch, "g"))
        find.addItem(finder("Find Previous", .previousMatch, "g", [.command, .shift]))
        find.addItem(finder("Use Selection for Find", .setSearchString, "e"))
        find.addItem(item("Jump to Selection", #selector(NSTextView.centerSelectionInVisibleArea(_:)), "j"))
        menu.addItem(submenu(find))

        let spelling = NSMenu(title: "Spelling and Grammar")
        spelling.addItem(item("Show Spelling and Grammar", #selector(NSText.showGuessPanel(_:)), ":"))
        spelling.addItem(item("Check Document Now", #selector(NSText.checkSpelling(_:)), ";"))
        spelling.addItem(.separator())
        spelling.addItem(item("Check Spelling While Typing", #selector(NSTextView.toggleContinuousSpellChecking(_:))))
        spelling.addItem(item("Check Grammar With Spelling", #selector(NSTextView.toggleGrammarChecking(_:))))
        spelling.addItem(item("Correct Spelling Automatically", #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))))
        menu.addItem(submenu(spelling))

        let substitutions = NSMenu(title: "Substitutions")
        substitutions.addItem(item("Show Substitutions", #selector(NSTextView.orderFrontSubstitutionsPanel(_:))))
        substitutions.addItem(.separator())
        substitutions.addItem(item("Smart Copy/Paste", #selector(NSTextView.toggleSmartInsertDelete(_:))))
        substitutions.addItem(item("Smart Quotes", #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))))
        substitutions.addItem(item("Smart Dashes", #selector(NSTextView.toggleAutomaticDashSubstitution(_:))))
        substitutions.addItem(item("Smart Markdown", #selector(EditorTextView.toggleSmartMarkdown(_:))))
        substitutions.addItem(item("Text Replacement", #selector(NSTextView.toggleAutomaticTextReplacement(_:))))
        menu.addItem(submenu(substitutions))
        return menu
    }

    private static func formatMenu() -> NSMenu {
        let menu = NSMenu(title: "Format")
        let shortcuts: [ParagraphStyle: String] = [.title: "1", .subtitle: "2", .heading: "3", .subheading: "4", .quote: "5", .body: "0"]
        for (index, style) in ParagraphStyle.allCases.enumerated() {
            let entry = item(style.displayName, #selector(EditorTextView.applyParagraphStyle(_:)), shortcuts[style] ?? "")
            entry.tag = index
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(item("Bold", #selector(EditorTextView.toggleBold(_:)), "b"))
        menu.addItem(item("Italic", #selector(EditorTextView.toggleItalic(_:)), "i"))
        menu.addItem(item("Underline", #selector(EditorTextView.toggleUnderline(_:)), "u"))
        menu.addItem(item("Strikethrough", #selector(EditorTextView.toggleStrikethrough(_:)), "x", [.command, .shift]))
        menu.addItem(item("Inline Code", #selector(EditorTextView.toggleCode(_:)), "c", [.command, .shift]))
        menu.addItem(item("Link…", #selector(EditorTextView.editLink(_:)), "k"))
        menu.addItem(.separator())
        menu.addItem(item("Bulleted List", #selector(EditorTextView.toggleBulletedList(_:)), "8", [.command, .shift]))
        menu.addItem(item("Numbered List", #selector(EditorTextView.toggleNumberedList(_:)), "7", [.command, .shift]))
        menu.addItem(.separator())
        let alignment = NSMenu(title: "Alignment")
        alignment.addItem(item("Left", #selector(EditorTextView.alignLeft(_:)), "l", [.command, .shift]))
        alignment.addItem(item("Center", #selector(EditorTextView.alignCenter(_:)), "e", [.command, .shift]))
        alignment.addItem(item("Right", #selector(EditorTextView.alignRight(_:)), "r", [.command, .shift]))
        menu.addItem(submenu(alignment))
        menu.addItem(.separator())
        let appearance = NSMenu(title: "Typeface")
        for (index, value) in Appearance.allCases.enumerated() {
            let entry = item(value.displayName, #selector(EditorViewController.applyAppearance(_:)))
            entry.tag = index
            appearance.addItem(entry)
        }
        menu.addItem(submenu(appearance))
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let appearance = NSMenu(title: "Appearance")
        for (index, value) in AppAppearance.allCases.enumerated() {
            let entry = item(value.displayName, #selector(AppAppearanceController.changeAppearance(_:)))
            entry.tag = index
            entry.target = AppAppearanceController.shared
            appearance.addItem(entry)
        }
        menu.addItem(submenu(appearance))
        menu.addItem(.separator())
        menu.addItem(item("Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option]))
        menu.addItem(item("Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"))
        menu.addItem(item("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    private static func item(
        _ title: String,
        _ action: Selector,
        _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = modifiers }
        return item
    }

    private static func finder(
        _ title: String,
        _ action: NSTextFinder.Action,
        _ key: String,
        _ modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let entry = item(title, #selector(NSTextView.performTextFinderAction(_:)), key, modifiers)
        entry.tag = action.rawValue
        return entry
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}
