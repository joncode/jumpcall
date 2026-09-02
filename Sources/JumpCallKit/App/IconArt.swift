import AppKit

/// The jumpcall character: a stick figure charging fist-first — Jumpman
/// hang-time energy, DK-charge elbow — leaping a barrel seen side-on (a
/// circle) that's bounding through the air (dotted bounce arc + landing
/// tick). Original geometry throughout; drawn in code on a 32-unit design
/// grid (no assets, no Xcode). Idle: the figure stands beside the resting
/// barrel. Live: the leap.
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
                NSBezierPath(ovalIn: NSRect(x: 24.5, y: 25.5, width: 6, height: 6)).fill()
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
        // charger: torso, uppercut arm, trailing arm, knee-drive leg, extended leg
        stroke([(10, 12), (12.8, 7)], color: color)
        stroke([(12.3, 8), (15, 9.6), (17, 6.4)], color: color)
        stroke([(12.4, 8.3), (9, 10)], color: color)
        stroke([(10, 12), (13.8, 13.4), (12.4, 16.6)], color: color)
        stroke([(10, 12), (7, 14.6), (4.6, 17.6)], color: color)
        dot(13.6, 4.7, 2.3, color: color)   // head
        dot(17.3, 5.9, 1.2, color: color)   // fist
        // barrel, airborne, mid-bounce
        circle(cx: 22.5, cy: 20, r: 4.5, width: 2.3, color: color)
        for tick: [(CGFloat, CGFloat)] in [
            [(22.5, 16.4), (22.5, 17.9)], [(26.1, 20), (24.6, 20)],
            [(22.5, 23.6), (22.5, 22.1)], [(18.9, 20), (20.4, 20)],
        ] {
            stroke(tick, width: 1.5, color: color)
        }
        // bounce arc (dotted) + landing tick
        let arc = NSBezierPath()
        arc.move(to: NSPoint(x: 30, y: 24.4))
        arc.curve(
            to: NSPoint(x: 24.9, y: 16.4),
            controlPoint1: NSPoint(x: 28.4, y: 19.5),
            controlPoint2: NSPoint(x: 26.7, y: 16.8))
        arc.lineWidth = 1.3
        arc.lineCapStyle = .round
        arc.setLineDash([0.1, 2.6], count: 2, phase: 0)
        color.setStroke()
        arc.stroke()
        stroke([(27.6, 26.4), (30.4, 25.6)], width: 1.6, color: color)
    }

    private static func drawIdle(color: NSColor) {
        // standing figure, waiting
        stroke([(9, 11.5), (9, 18)], color: color)
        stroke([(9, 12.6), (6.8, 15.4)], color: color)
        stroke([(9, 12.6), (11.2, 15.4)], color: color)
        stroke([(9, 18), (7.6, 22.6)], color: color)
        stroke([(9, 18), (10.4, 22.6)], color: color)
        dot(9, 9, 2.4, color: color)
        // resting barrel: cross-slats instead of roll ticks
        circle(cx: 24, cy: 24.5, r: 5, width: 2.3, color: color)
        stroke([(21.2, 21.7), (26.8, 27.3)], width: 1.5, color: color)
        stroke([(26.8, 21.7), (21.2, 27.3)], width: 1.5, color: color)
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

    private static func stroke(_ points: [(CGFloat, CGFloat)], width: CGFloat = 2.3, color: NSColor) {
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
