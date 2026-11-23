# hermes

A quiet Mac writing app with paragraph styles. Open a document, write, give it structure, export something clean.

## Build and run

Requires macOS 14+, the Xcode Command Line Tools (full Xcode not needed), and Rust (`rustup`).

```sh
scripts/build-app.sh          # builds, signs, and installs /Applications/Hermes Writer.app
open "/Applications/Hermes Writer.app"
```

Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution; notarization is a separate `xcrun notarytool` step.

## Tests

```sh
scripts/test.sh                                # runs all three suites (bundles the harness for Finder drop & type checks)
(cd core && cargo test)                        # Rust document core
swift run HermesKitTests                       # Swift model, styling, paste, export
swift run HermesAppHarness /tmp/hermes-harness # drives the real editor; writes PNG renders, PDF, RTF, TXT
```

The Swift suites run as executables because `swift test` cannot discover Swift Testing suites with only the Command Line Tools installed.

## Window

Hermes uses a square, opaque window frame with a thin outline and a flat 44-point header. Drag the header to move the window; double-click it to zoom (or minimize, following the Mac’s setting). The window buttons close, minimize, or enter full screen; Option-click the green button to zoom. The custom close action preserves the document’s save prompt. Double-click the document name to rename it; unsaved drafts can be named before saving, and saved documents keep their file extension. The edited indicator uses secondary text color. The header shows the document name, edited state and word count, with borderless style and formatting controls. Both Light and Dark appearance apply to the frame. Hovering anywhere over the three window controls reveals their symbols together; leaving the group hides them. The controls also show pressed feedback and retain the unsaved-document dot in the close button.

## Typeface and appearance

The interface uses native AppKit controls and the macOS system UI font. Document typefaces are independent: Serif uses Apple's system serif design, Sans Serif uses the system font, Mono uses the system monospaced design, and Classic uses Charter when available.

Use the **Aa** popover to choose a document typeface or **System / Light / Dark** app appearance. Appearance is also available under **View → Appearance**, applies to every document window, and is remembered between launches. System follows the Mac's appearance setting. Typeface is saved with the document; app appearance does not change the document or its exports.

The popover also includes **Size (pt)**, **Letter spacing**, **Line height**, and **Alignment**. Type any whole number from 8–144 points or use the up/down arrows to change it by 1 point. Size applies to the selection, or to new typing at the cursor; Enter **Style Default** to restore the paragraph style's size. Line height displays the current multiplier from 1× to 3×; type a custom value or use the arrows to change it by 0.1×. Enter **Style Default** to restore the style's spacing. Line height and left, center, or right alignment apply to the current paragraph or selected paragraphs. These settings survive saving, Hermes copy/paste, and PDF/RTF export. Plain text contains no formatting. Existing version 1–3 documents still open; saving writes format version 4. Letter spacing applies to selected text or new typing, from −5 to 20 points in 0.1-point steps. Zero (or Style Default) restores natural spacing; mixed selections display Mixed. Letter spacing survives saving, internal copy/paste, and PDF/RTF export.

## Layout

| Path | What lives there |
| --- | --- |
| `core/` | Rust: document model, `.hrms` file format (versioning, validation, normalization), plain-text export, word count, C ABI |
| `Sources/CHermesCore/` | C header and module map for the Rust static library |
| `Sources/HermesKit/` | Swift model mirror, Rust bridge, typography themes, style engine, attributed-string conversion, paste normalization, PDF/RTF export |
| `Sources/HermesApp/` | AppKit: `NSDocument`, square window, custom header, format popover, the TextKit 2 editor, list-marker drawing, menus |
| `Sources/Hermes/` | Executable entry point |

## How it works

Paragraph styles use a 32 pt title, 18 pt subtitle, 24 pt heading, 18 pt subheading, and 16 pt body and quote (with the existing compact scale for Monospaced). Quotes use italics, normal text contrast, and a modest left indent. Choosing a paragraph style applies its default size and line spacing to the touched paragraphs while preserving emphasis, links, alignment, and explicit letter spacing. Return after a title, subtitle, heading, or subheading starts clean Body text. Mixed selections show “Mixed Styles.”

Updated presets also apply when opening existing documents; explicit formatting overrides remain until a paragraph style is reapplied. The document format is unchanged.

The editor's text storage carries semantic attributes only — paragraph style, list kind, bold/italic/underline, link. Fonts, spacing and colors are derived from them by `StyleEngine` in a separate attribute update after each text edit, so typing, paste, undo and appearance changes all land consistently styled, and changing a style's look updates every paragraph that uses it.

Documents cross into Rust as JSON when saved and opened; nothing crosses per keystroke except a debounced word count. Rust owns the file format: it rejects foreign, newer-version and malformed files with a readable message, and writes a canonical one-paragraph-per-line JSON file.

List markers are drawn by a custom TextKit 2 layout fragment rather than inserted into the text, so they never appear in the model. Export turns them into literal text so they survive RTF and PDF.

## Shortcuts

| | |
| --- | --- |
| Title / Subtitle / Heading / Subheading / Quote | ⌘1 ⌘2 ⌘3 ⌘4 ⌘5 |
| Body | ⌘0 |
| Bold / Italic / Underline / Strikethrough / Inline Code / Link | ⌘B ⌘I ⌘U ⇧⌘X ⇧⌘C ⌘K |
| Align Left / Center / Right | ⇧⌘L ⇧⌘E ⇧⌘R |
| Bulleted / Numbered list | ⇧⌘8 ⇧⌘7 |
| Find / Find and Replace | ⌘F ⌥⌘F |
| Full screen | ⌃⌘F |

Smart Markdown typing triggers (`# `, `## `, `### `, `> `, `- `, `* `, `1. `, `**bold**`, `*italic*`, `~~strikethrough~~`, `` `code` ``) can be toggled under **Edit → Substitutions → Smart Markdown**.

## Updates and releases

Hermes checks GitHub Releases (`ninthdensity/hermes`) for newer versions automatically once per day (toggleable via **hermes → Automatically Check for Updates**) or on demand via **hermes → Check for Updates…**. When a newer version is found, Hermes displays the release notes and lets you download, verify, and install the update directly.

To package a release `.zip` for GitHub Releases:

```sh
scripts/package-release.sh    # outputs dist/Hermes-Writer-<version>-macos.zip and its SHA-256 checksum
```

## Branding and compatibility

The app is **hermes**. `Resources/Logo.png` is the supplied emblem; `Resources/AppIcon.icns` contains the macOS icon sizes derived from it. Run `swift scripts/make-icon.swift` to regenerate the icon.

New documents use `.hrms` (format version 5, backward-compatible with versions 1–4), which keeps all Hermes formatting. Use **File → Open** to edit a UTF-8 `.md` or `.markdown` file and **Save** to write it back as Markdown. Headings at levels 1–3, quotes, flat lists, links, bold, italics, strikethrough, and inline code use the formatted editor. Files with unsupported structures such as front matter, tables, fenced code blocks, or nested lists open in an editable source view. Saving edits in the formatted editor can normalize the Markdown syntax. Custom typography is available in the Hermes format.

Use **File → Export To → Markdown** to create a Markdown copy of a Hermes document, or **Hermes Document** to save a copy of a Markdown document as `.hrms`.

Drop `.md`, `.markdown`, or `.hrms` files from Finder onto a Hermes document window to open them in separate windows.
