import AppKit

/// The standard title-bar tracking region is absent from a borderless window.
/// Keep standard button actions/accessibility, and explicitly draw and track the group.
final class WindowButtonsView: NSView {
    private(set) var buttons: [NSWindow.ButtonType: NSButton] = [:]
    private(set) var isHovered = false
    private var hoverTrackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        for (index, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            let button = WindowControlButton(type: type)
            button.frame = NSRect(x: 6 + index * 20, y: 7, width: 14, height: 14)
            button.group = self
            buttons[type] = button
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self)
        if let window {
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                center.addObserver(self, selector: #selector(refreshButtons), name: name, object: window)
            }
            for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                center.addObserver(self, selector: #selector(refreshButtons), name: name, object: NSApp)
            }
        }
        refreshButtons()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                                  owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
        isHovered = window.map { bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
        refreshButtons()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        refreshButtons()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        refreshButtons()
    }

    override func mouseDown(with event: NSEvent) { superview?.mouseDown(with: event) }

    @objc func refreshButtons() {
        for button in buttons.values { button.needsDisplay = true }
    }
}

private final class WindowControlButton: NSButton {
    let controlType: NSWindow.ButtonType
    weak var group: WindowButtonsView?

    init(type: NSWindow.ButtonType) {
        controlType = type
        super.init(frame: .zero)
        setButtonType(.momentaryChange)
        isBordered = false
        title = ""
        switch type {
        case .closeButton:
            setAccessibilitySubrole(.closeButton)
            setAccessibilityLabel("Close")
            toolTip = "Close"
        case .miniaturizeButton:
            setAccessibilitySubrole(.minimizeButton)
            setAccessibilityLabel("Minimize")
            toolTip = "Minimize"
        default:
            setAccessibilitySubrole(.fullScreenButton)
            setAccessibilityLabel("Full Screen")
            toolTip = "Enter Full Screen (Option-click to zoom)"
            setAccessibilityCustomActions([
                NSAccessibilityCustomAction(name: "Zoom Window", target: self, selector: #selector(zoomWindow)),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func zoomWindow() -> Bool {
        guard let window else { return false }
        window.zoom(nil)
        return true
    }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        let hovered = group?.isHovered == true
        let active = isEnabled && (hovered || (NSApp.isActive && (window?.isKeyWindow == true || window?.isMainWindow == true)))
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var color: NSColor
        if active {
            switch controlType {
            case .closeButton: color = NSColor(srgbRed: 1, green: 0.37, blue: 0.34, alpha: 1)
            case .miniaturizeButton: color = NSColor(srgbRed: 1, green: 0.74, blue: 0.18, alpha: 1)
            default: color = NSColor(srgbRed: 0.16, green: 0.79, blue: 0.25, alpha: 1)
            }
        } else {
            color = NSColor(white: dark ? 0.31 : 0.83, alpha: 1)
        }
        if isHighlighted { color = color.blended(withFraction: 0.18, of: .black) ?? color }
        let circle = NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5))
        color.setFill()
        circle.fill()
        NSColor.black.withAlphaComponent(dark ? 0.25 : 0.12).setStroke()
        circle.lineWidth = 0.5
        circle.stroke()

        let ink = NSColor.black.withAlphaComponent(0.60)
        ink.setStroke()
        ink.setFill()
        let center = NSPoint(x: bounds.midX, y: bounds.midY)
        guard hovered && isEnabled else {
            if controlType == .closeButton && window?.isDocumentEdited == true {
                NSBezierPath(ovalIn: NSRect(x: center.x - 1.5, y: center.y - 1.5, width: 3, height: 3)).fill()
            }
            return
        }
        let glyph = NSBezierPath()
        glyph.lineWidth = 1.1
        switch controlType {
        case .closeButton:
            glyph.move(to: NSPoint(x: center.x - 2.5, y: center.y - 2.5))
            glyph.line(to: NSPoint(x: center.x + 2.5, y: center.y + 2.5))
            glyph.move(to: NSPoint(x: center.x - 2.5, y: center.y + 2.5))
            glyph.line(to: NSPoint(x: center.x + 2.5, y: center.y - 2.5))
            glyph.stroke()
        case .miniaturizeButton:
            glyph.move(to: NSPoint(x: center.x - 3, y: center.y))
            glyph.line(to: NSPoint(x: center.x + 3, y: center.y))
            glyph.stroke()
        default:
            for direction: CGFloat in [-1, 1] {
                glyph.move(to: NSPoint(x: center.x + direction * 3, y: center.y + direction * 3))
                glyph.line(to: NSPoint(x: center.x, y: center.y + direction * 3))
                glyph.line(to: NSPoint(x: center.x + direction * 3, y: center.y))
                glyph.close()
            }
            glyph.fill()
        }
    }
}
