import AppKit

/// Shared vector geometry for the application icon and menu-bar template.
enum AppIcon {
    static func drawBranch(in rect: NSRect, color: NSColor) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
        transform.scale(x: rect.width / 100, y: rect.height / 100)
        (transform as NSAffineTransform).concat()
        color.setStroke()
        color.setFill()
        let branch = NSBezierPath()
        branch.lineWidth = 9
        branch.lineCapStyle = .round
        branch.lineJoinStyle = .round
        branch.move(to: NSPoint(x: 34, y: 20))
        branch.line(to: NSPoint(x: 34, y: 80))
        branch.move(to: NSPoint(x: 34, y: 40))
        branch.curve(to: NSPoint(x: 72, y: 75),
                     controlPoint1: NSPoint(x: 34, y: 60), controlPoint2: NSPoint(x: 72, y: 51))
        branch.stroke()
        for center in [NSPoint(x: 34, y: 20), NSPoint(x: 34, y: 80), NSPoint(x: 72, y: 75)] {
            NSBezierPath(ovalIn: NSRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)).fill()
        }
    }

    static var menuBar: NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { bounds in
            drawBranch(in: bounds.insetBy(dx: 1, dy: 1), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "JustGit"
        return image
    }

    static func drawApplication(in bounds: NSRect) {
        let unit = bounds.width / 512
        func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
            NSColor(srgbRed: r, green: g, blue: b, alpha: a)
        }
        func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        }
        let tile = bounds.insetBy(dx: 38 * unit, dy: 42 * unit).offsetBy(dx: 0, dy: 8 * unit)
        let radius = 98 * unit
        let base = rounded(tile.offsetBy(dx: 0, dy: -10 * unit), radius)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0.38, 0.35, 0.48, 0.18)
        shadow.shadowBlurRadius = 14 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -9 * unit)
        shadow.set()
        color(0.80, 0.80, 0.91, 0.90).setFill()
        base.fill()
        NSGraphicsContext.restoreGraphicsState()

        // The lower rim remains visible below the translucent face.
        NSGradient(starting: color(0.75, 0.78, 0.88), ending: color(0.94, 0.98, 1))?
            .draw(in: base, angle: 90)
        let face = rounded(tile, radius)
        NSGradient(colors: [color(0.79, 0.89, 0.98, 0.94), color(0.96, 0.94, 0.99, 0.94), color(1, 0.85, 0.91, 0.95)])?
            .draw(in: face, angle: 55)
        NSGraphicsContext.saveGraphicsState()
        face.addClip()
        let light = NSBezierPath(ovalIn: NSRect(x: tile.minX - 90 * unit, y: tile.midY - 10 * unit,
                                               width: 590 * unit, height: 350 * unit))
        NSGradient(starting: color(1, 1, 1, 0.03), ending: color(1, 1, 1, 0.82))?
            .draw(in: light, angle: 90)
        let caustic = NSBezierPath()
        caustic.move(to: NSPoint(x: tile.minX + 45 * unit, y: tile.minY + 26 * unit))
        caustic.curve(to: NSPoint(x: tile.maxX - 35 * unit, y: tile.minY + 40 * unit),
                     controlPoint1: NSPoint(x: tile.midX - 50 * unit, y: tile.minY + 3 * unit),
                     controlPoint2: NSPoint(x: tile.midX + 95 * unit, y: tile.minY + 12 * unit))
        caustic.lineWidth = 2 * unit
        caustic.lineCapStyle = .round
        color(1, 1, 1, 0.5).setStroke()
        caustic.stroke()
        NSGraphicsContext.restoreGraphicsState()
        face.lineWidth = 2 * unit
        color(1, 1, 1, 0.95).setStroke()
        face.stroke()
        let inner = rounded(tile.insetBy(dx: 9 * unit, dy: 9 * unit), radius - 7 * unit)
        inner.lineWidth = 1.5 * unit
        color(0.60, 0.73, 0.82, 0.34).setStroke()
        inner.stroke()

        let mark = bounds.insetBy(dx: bounds.width * 0.20, dy: bounds.height * 0.20)
            .offsetBy(dx: 0, dy: 8 * unit)
        NSGraphicsContext.saveGraphicsState()
        shadow.shadowColor = color(0.38, 0.37, 0.55, 0.20)
        shadow.shadowBlurRadius = 7 * unit
        shadow.shadowOffset = NSSize(width: 1 * unit, height: -7 * unit)
        shadow.set()
        drawBranch(in: mark.offsetBy(dx: 0, dy: -6 * unit), color: color(0.49, 0.53, 0.70))
        NSGraphicsContext.restoreGraphicsState()
        for step in stride(from: 6, through: 0, by: -1) {
            let t = CGFloat(6 - step) / 6
            drawBranch(in: mark.offsetBy(dx: 0, dy: -CGFloat(step) * unit),
                       color: color(0.50 + 0.16 * t, 0.55 + 0.16 * t, 0.73 + 0.14 * t))
        }
        // Rounded node caps catch the same upper-left light as the tile.
        for center in [NSPoint(x: 34, y: 20), NSPoint(x: 34, y: 80), NSPoint(x: 72, y: 75)] {
            let size = mark.width * 0.20
            let cap = NSBezierPath(ovalIn: NSRect(x: mark.minX + mark.width * center.x / 100 - size / 2,
                                                y: mark.minY + mark.height * center.y / 100 - size / 2,
                                                width: size, height: size))
            NSGradient(colors: [color(0.59, 0.67, 0.85), color(0.85, 0.89, 0.98), color(1, 0.92, 0.96)])?
                .draw(in: cap, angle: 110)
            cap.lineWidth = 1 * unit
            color(1, 1, 1, 0.6).setStroke()
            cap.stroke()
        }
    }
}
