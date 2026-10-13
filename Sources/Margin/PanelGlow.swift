import AppKit

/// A soft light-orange glow around a chat popup. It lives in its own click-through window just
/// behind the chat and follows it every frame (moves, resizes, fades), so the chat's own code
/// doesn't have to know about it. It blooms out brighter each time the chat pops up, then settles.
final class PanelGlow {
    static let color = NSColor(srgbRed: 1.0, green: 0.71, blue: 0.47, alpha: 1) // light orange, #FFB578
    /// How far the glow can reach past the chat's edge.
    static let reach: CGFloat = 56

    private weak var panel: NSWindow?
    private let window: GlowWindow
    private let view: GlowRectView
    private var timer: Timer?

    init(around panel: NSWindow, cornerRadius: CGFloat) {
        self.panel = panel
        view = GlowRectView(cornerRadius: cornerRadius, reach: Self.reach)
        window = GlowWindow(size: NSSize(width: 10, height: 10), canKey: false)
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.keepsBelowMenuBar = false // the glow may reach past the screen's edge
        window.level = panel.level
        window.contentView = view
        view.autoresizingMask = [.width, .height]
    }

    /// The chat just appeared (or grew back out of its sidebar circle): show the glow and bloom.
    func popped() {
        follow()
        view.bloom()
        guard timer == nil else { return }
        // The timer holds the glow until its window is gone, even if the chat that owns it is released
        // first (closing a chat drops it right away). Otherwise the glow would be stranded on screen.
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in self.follow() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        window.orderOut(nil)
    }

    deinit { window.orderOut(nil) }

    /// Glow windows still on screen (for --glowtest: none should outlive their chat).
    static var visibleWindowCount: Int { NSApp.windows.filter { $0 is GlowWindow && $0.isVisible }.count }

    /// Matches the chat's frame and fade. Stops by itself once the chat is off screen.
    private func follow() {
        guard let panel, panel.isVisible else { return remove() }
        let frame = panel.frame.insetBy(dx: -Self.reach, dy: -Self.reach)
        if window.frame != frame { window.setFrame(frame, display: true) }
        if window.alphaValue != panel.alphaValue { window.alphaValue = panel.alphaValue }
        if !window.isVisible || window.level != panel.level {
            window.level = panel.level
            window.order(.below, relativeTo: panel.windowNumber)
        }
    }

    // For --glowtest.
    var debugFrame: NSRect { window.frame }
    /// The glow as it looks right now, with `chat` (a snapshot of the chat) drawn over it, on a dark backdrop.
    func debugImage(chat: CGImage?) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil } // already 2x
        ctx.setFillColor(NSColor(white: 0.12, alpha: 1).cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        view.renderGlow(in: ctx)
        if let chat {
            ctx.draw(chat, in: CGRect(origin: .zero, size: size).insetBy(dx: Self.reach, dy: Self.reach))
        }
        return rep
    }
    var debugIsVisible: Bool { window.isVisible }
    var debugAlpha: CGFloat { window.alphaValue }
}

private final class GlowWindow: FloatingPanel {}

/// Draws the glow: a shadow cast by the chat's rounded rectangle, cut out where the chat is,
/// so none of it shows through the chat's frosted background.
private final class GlowRectView: NSView {
    private let cornerRadius: CGFloat
    private let reach: CGFloat
    private let caster = CALayer()
    private let cutout = CAShapeLayer()

    private static let restRadius: CGFloat = 18
    private static let restOpacity: Float = 0.85

    init(cornerRadius: CGFloat, reach: CGFloat) {
        self.cornerRadius = cornerRadius
        self.reach = reach
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        wantsLayer = true
        caster.shadowColor = PanelGlow.color.cgColor
        caster.shadowOffset = .zero
        caster.shadowRadius = Self.restRadius
        caster.shadowOpacity = Self.restOpacity
        cutout.fillRule = .evenOdd
        cutout.fillColor = NSColor.black.cgColor
        caster.mask = cutout
        layer?.addSublayer(caster)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        caster.frame = bounds
        cutout.frame = bounds
        let chat = bounds.insetBy(dx: reach, dy: reach)
        let shape = CGPath(roundedRect: chat, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        caster.shadowPath = shape
        let hole = CGMutablePath()
        hole.addRect(bounds)
        hole.addPath(shape)
        cutout.path = hole
        CATransaction.commit()
    }

    /// Core Animation's offscreen `render(in:)` skips this masked shadow, so the test picture draws the
    /// equivalent Core Graphics shadow (blur ≈ 2× the layer's shadow radius); the chat's picture covers the middle.
    func renderGlow(in ctx: CGContext) {
        let now = caster.presentation() ?? caster
        guard let shape = caster.shadowPath else { return }
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: now.shadowRadius * 2,
                      color: PanelGlow.color.withAlphaComponent(CGFloat(now.shadowOpacity)).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// Brighter and wider for a moment, then settles to a gentle steady glow.
    func bloom() {
        let radius = CABasicAnimation(keyPath: "shadowRadius")
        radius.fromValue = 32
        radius.toValue = Self.restRadius
        let opacity = CABasicAnimation(keyPath: "shadowOpacity")
        opacity.fromValue = 1
        opacity.toValue = Self.restOpacity
        let group = CAAnimationGroup()
        group.animations = [radius, opacity]
        group.duration = 1.1
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.7, 0.3, 1)
        caster.add(group, forKey: "bloom")
    }
}
