import AppKit
import HermesKit

/// Draws a list marker in the indent of a list paragraph, so markers never enter the text.
final class ListItemLayoutFragment: NSTextLayoutFragment {
    private static let gap: CGFloat = 8

    private var marker = NSAttributedString()

    convenience init(paragraph: NSTextParagraph, list: ListKind) {
        self.init(textElement: paragraph, range: paragraph.elementRange)
        let s = paragraph.attributedString
        let font = s.attribute(.font, at: 0, effectiveRange: nil) as? NSFont ?? .systemFont(ofSize: 16)
        let color = s.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor ?? .textColor
        let label: String = switch list {
        case .bullet: "•"
        case .number: "\(s.attribute(.hermesListOrdinal, at: 0, effectiveRange: nil) as? Int ?? 1)."
        }
        marker = NSAttributedString(string: label, attributes: [
            .font: NSFontManager.shared.convert(font, toNotHaveTrait: [.boldFontMask, .italicFontMask]),
            .foregroundColor: color,
        ])
    }

    private var markerFrame: CGRect {
        guard let line = textLineFragments.first, marker.length > 0 else { return .null }
        let size = marker.size()
        let font = marker.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let baseline = line.typographicBounds.minY + line.glyphOrigin.y
        return CGRect(
            x: line.typographicBounds.minX - Self.gap - size.width,
            y: baseline - (font?.ascender ?? size.height),
            width: size.width,
            height: size.height
        )
    }

    override var renderingSurfaceBounds: CGRect {
        super.renderingSurfaceBounds.union(markerFrame)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        super.draw(at: point, in: context)
        let frame = markerFrame
        guard !frame.isNull else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        marker.draw(at: CGPoint(x: point.x + frame.minX, y: point.y + frame.minY))
        NSGraphicsContext.restoreGraphicsState()
    }
}
