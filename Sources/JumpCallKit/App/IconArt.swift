import AppKit

/// The jumpcall character: a wide, chunky stick figure charging fist-first
/// — Jumpman hang-time energy, DK-charge elbow, original geometry — leaping
/// a barrel seen side-on (a circle with roll ticks) that's airborne above a
/// corner of hillside. Idle: the figure stands beside the resting barrel
/// (cross-slat end). Drawn in code as bold bezier strokes on a 32-unit
/// grid (no assets, no Xcode); tuned for 18pt menu-bar legibility.
enum IconArt {
    private static let design: CGFloat = 32
    private static let pointSize: CGFloat = 18

    static func idle() -> NSImage {
        let image = canvas { drawIdle(color: .black) }
        image.isTemplate = true
        return image
    }

    static func live(style: String) -> NSImage {
        if style == "badge" {
            // labelColor resolves per-appearance at draw time (the drawing
            // handler runs lazily), so the art adapts while the dot stays green.
            let image = canvas {
                drawLive(color: .labelColor)
                NSColor.systemGreen.setFill()
                NSBezierPath(ovalIn: NSRect(x: 1.5, y: 25, width: 6, height: 6)).fill()
            }
            image.isTemplate = false
            return image
        }
        let image = canvas { drawLive(color: .systemGreen) }
        image.isTemplate = false
        return image
    }

    // MARK: - Scenes

    private static func drawLive(color: NSColor) {
        // charger: torso, wide uppercut arm, trailing arm, knee drive, extended leg
        stroke([(8, 15), (11.8, 8.5)], color: color)
        stroke([(11.3, 9.5), (15.8, 11.2), (19.6, 6.8)], color: color)
        stroke([(11.4, 10), (5.8, 12.2)], color: color)
        stroke([(8, 15), (14.2, 16.8), (12.2, 21.6)], color: color)
        stroke([(8, 15), (3.8, 18.6), (1.6, 22.8)], color: color)
        dot(12.6, 4.9, 3.0, color: color)   // head
        dot(20.3, 5.9, 1.9, color: color)   // fist
        // barrel, airborne, roll ticks
        circle(cx: 25, cy: 21.2, r: 6, width: 3.2, color: color)
        for tick: [(CGFloat, CGFloat)] in [
            [(25, 16.1), (25, 18.2)], [(30.1, 21.2), (28, 21.2)],
            [(25, 26.3), (25, 24.2)], [(19.9, 21.2), (22, 21.2)],
        ] {
            stroke(tick, width: 2.2, color: color)
        }
        // corner of hillside, clearly below the airborne barrel
        stroke([(27.2, 31.8), (32, 29.2)], width: 2.8, color: color)
    }

    private static func drawIdle(color: NSColor) {
        // standing figure, waiting
        stroke([(8, 10.5), (8, 17.5)], color: color)
        stroke([(8, 12), (4.6, 15.2)], color: color)
        stroke([(8, 12), (11.4, 15.2)], color: color)
        stroke([(8, 17.5), (5.6, 22.8)], color: color)
        stroke([(8, 17.5), (10.4, 22.8)], color: color)
        dot(8, 7.5, 3.0, color: color)
        // resting barrel: cross-slat end
        circle(cx: 24, cy: 23.5, r: 6, width: 3.2, color: color)
        stroke([(20.6, 20.1), (27.4, 26.9)], width: 2.2, color: color)
        stroke([(27.4, 20.1), (20.6, 26.9)], width: 2.2, color: color)
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

    private static func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat = 3.4, color: NSColor) {
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

    private static func circle(cx: CGFloat, cy: CGFloat, r: CGFloat, width: CGFloat, color: NSColor) {
        let path = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        path.lineWidth = width
        color.setStroke()
        path.stroke()
    }

    private static func dot(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
}
