import AppKit

/// The jumpcall mark: a chunky stick figure facing the viewer, mid-leap —
/// both arms thrown up with bent elbows, hands as dots, legs spread wide.
/// The same character is both states: template (adapts to the menu bar)
/// when no call is live, green when one is. Original geometry, drawn in
/// code as bold bezier strokes on a 32-unit grid (no assets, no Xcode),
/// tuned for 18pt menu-bar legibility.
enum IconArt {
    private static let design: CGFloat = 32
    private static let pointSize: CGFloat = 18

    static func idle() -> NSImage {
        let image = canvas { drawFigure(color: .black) }
        image.isTemplate = true
        return image
    }

    static func live(style: String) -> NSImage {
        if style == "badge" {
            // labelColor resolves per-appearance at draw time (the drawing
            // handler runs lazily), so the art adapts while the dot stays green.
            let image = canvas {
                drawFigure(color: .labelColor)
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: 13, y: 25.5, width: 6, height: 6)).fill()
            }
            image.isTemplate = false
            return image
        }
        let image = canvas { drawFigure(color: .systemGreen) }
        image.isTemplate = false
        return image
    }

    // MARK: - The character

    private static func drawFigure(color: NSColor) {
        stroke([(16, 10.2), (16, 19)], color: color)                     // torso
        stroke([(16, 12), (9.8, 10), (8.2, 4.4)], color: color)          // left arm, elbow out
        stroke([(16, 12), (22.2, 10), (23.8, 4.4)], color: color)        // right arm, elbow out
        stroke([(16, 19), (10.4, 23.2), (8.4, 28.6)], color: color)      // left leg spread
        stroke([(16, 19), (21.6, 23.2), (23.6, 28.6)], color: color)     // right leg spread
        dot(16, 5.2, 4.0, color: color)                                  // head
        dot(7.9, 3.6, 2.2, color: color)                                 // left hand
        dot(24.1, 3.6, 2.2, color: color)                                // right hand
    }

    // MARK: - Drawing primitives (32-unit space scaled to 18pt)

    private static func canvas(_ draw: @escaping () -> Void) -> NSImage {
        NSImage(size: NSSize(width: pointSize, height: pointSize), flipped: true) { _ in
            let transform = NSAffineTransform()
            transform.scale(by: pointSize / design)
            transform.concat()
            draw()
            return true
        }
    }

    private static func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat = 4.4, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: points[0].0, y: points[0].1))
        for point in points.dropFirst() {
            path.line(to: NSPoint(x: point.0, y: point.1))
        }
        color.setStroke()
        path.stroke()
    }

    private static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
}
