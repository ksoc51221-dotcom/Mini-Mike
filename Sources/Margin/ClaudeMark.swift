import AppKit

/// Margin's mark: a Claude-style spark (a starburst of rounded rays), drawn in code so it stays
/// crisp at every size. Used for the trigger bubble, the menu bar, the app icon and the sidebar circles.
enum ClaudeMark {
    /// Twelve rays, slightly irregular like a hand-drawn spark: (angle in degrees, length 0…1).
    private static let rays: [(angle: CGFloat, length: CGFloat)] = [
        (90, 1.00), (121, 0.80), (149, 0.93), (182, 0.72), (209, 0.97), (241, 0.83),
        (269, 0.90), (302, 0.75), (329, 1.00), (2, 0.82), (31, 0.92), (60, 0.71),
    ]

    /// Ray thickness as a fraction of the radius.
    static let strokeWidth: CGFloat = 0.19

    /// The rays as line segments from the center. Stroke with `lineWidth(radius:)` and round caps.
    static func path(center: CGPoint, radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let reach = radius * (1 - strokeWidth / 2) // round caps must stay inside the radius
        for ray in rays {
            let a = ray.angle * .pi / 180
            path.move(to: center)
            path.addLine(to: CGPoint(x: center.x + cos(a) * reach * ray.length,
                                     y: center.y + sin(a) * reach * ray.length))
        }
        return path
    }

    static func lineWidth(radius: CGFloat) -> CGFloat { radius * strokeWidth }

    /// A ready-to-use layer for the spark, sized to `rect` (rotates around its center).
    static func layer(in rect: CGRect, color: NSColor) -> CAShapeLayer {
        let layer = CAShapeLayer()
        layer.frame = rect
        let r = min(rect.width, rect.height) / 2
        layer.path = path(center: CGPoint(x: rect.width / 2, y: rect.height / 2), radius: r)
        layer.lineWidth = lineWidth(radius: r)
        layer.lineCap = .round
        layer.fillColor = nil
        layer.strokeColor = color.cgColor
        return layer
    }

    static func draw(in rect: NSRect, color: NSColor) {
        let r = min(rect.width, rect.height) / 2
        let bezier = NSBezierPath(cgPath: path(center: CGPoint(x: rect.midX, y: rect.midY), radius: r))
        bezier.lineWidth = lineWidth(radius: r)
        bezier.lineCapStyle = .round
        color.setStroke()
        bezier.stroke()
    }

    /// Monochrome template image for the menu bar (tinted by macOS for light/dark menu bars).
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            draw(in: rect.insetBy(dx: 2, dy: 2), color: .black)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Margin"
        return image
    }

    /// App icon artwork: a terracotta spark on a warm ivory tile.
    static func appIconPNG(pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx

        let s = CGFloat(pixels)
        // macOS icon grid: the tile is ~80% of the canvas, leaving room for its shadow.
        let tile = NSRect(x: s * 0.1, y: s * 0.1, width: s * 0.8, height: s * 0.8)
        let shape = NSBezierPath(roundedRect: tile, xRadius: s * 0.18, yRadius: s * 0.18)

        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
        shadow.shadowOffset = NSSize(width: 0, height: -s * 0.012)
        shadow.shadowBlurRadius = s * 0.03
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        Theme.ivory.setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(starting: NSColor(srgbRed: 0.985, green: 0.97, blue: 0.945, alpha: 1),
                   ending: NSColor(srgbRed: 0.93, green: 0.905, blue: 0.865, alpha: 1))?
            .draw(in: shape, angle: -90)

        let markSize = s * 0.5
        draw(in: NSRect(x: (s - markSize) / 2, y: (s - markSize) / 2, width: markSize, height: markSize),
             color: Theme.accent)

        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// `Margin --render-icon <dir>`: writes a complete .iconset for `iconutil`.
    static func renderIconset(to directory: String) -> Never {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for points in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
                try? appIconPNG(pixels: points * scale)?.write(to: dir.appendingPathComponent(name))
            }
        }
        exit(0)
    }
}
