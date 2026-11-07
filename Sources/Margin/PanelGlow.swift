import AppKit

/// The chat popup's lift: one soft black shadow (@0.4, y 12, r 32) with a faint accent halo hugging the edge. It lives in its own click-through window just
/// behind the chat and follows it every frame (moves, resizes, fades), so the chat's own code
/// doesn't have to know about it. It blooms out brighter each time the chat pops up, then settles.
final class PanelGlow {
    static let color = Theme.accent.light // only used at 0 opacity now
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

    /// The chat came to the front (you clicked it among several): its glow goes back to sitting right behind it.
    func restack() {
        guard let panel, panel.isVisible, window.isVisible else { return }
        window.order(.below, relativeTo: panel.windowNumber)
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
        ctx.setFillColor(Theme.canvas.dark.cgColor)
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
    private let dropShadow = CALayer()
    private let cutout = CAShapeLayer()
    private var hostLayer = CALayer()

    private static let restRadius: CGFloat = 10
    private static let restOpacity: Float = 0 // no accent halo any more: only the neutral drop shadow remains

    init(cornerRadius: CGFloat, reach: CGFloat) {
        self.cornerRadius = cornerRadius
        self.reach = reach
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
        wantsLayer = true
        caster.shadowColor = PanelGlow.color.cgColor
        caster.shadowOffset = .zero
        caster.shadowRadius = Self.restRadius
        caster.shadowOpacity = Self.restOpacity
        dropShadow.shadowColor = NSColor.black.cgColor
        dropShadow.shadowOffset = CGSize(width: 0, height: -12) // AppKit layers are bottom-up: negative y falls downward
        dropShadow.shadowRadius = 16 // CA radius is half the CSS blur: blur 32
        dropShadow.shadowOpacity = 0.4
        cutout.fillRule = .evenOdd
        cutout.fillColor = NSColor.black.cgColor
        let host = CALayer()
        host.mask = cutout
        host.addSublayer(dropShadow)
        host.addSublayer(caster)
        hostLayer = host
        layer?.addSublayer(host)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hostLayer.frame = bounds
        caster.frame = bounds
        dropShadow.frame = bounds
        cutout.frame = bounds
        let chat = bounds.insetBy(dx: reach, dy: reach)
        let shape = CGPath(roundedRect: chat, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        caster.shadowPath = shape
        dropShadow.shadowPath = shape
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
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 32, color: NSColor.black.withAlphaComponent(0.4).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: now.shadowRadius * 2,
                      color: PanelGlow.color.withAlphaComponent(CGFloat(now.shadowOpacity)).cgColor)
        ctx.addPath(shape)
        ctx.setFillColor(NSColor.black.cgColor)
        ctx.fillPath()
        ctx.restoreGState()
    }

    /// The accent bloom is gone (lime is for one primary per view); kept so callers stay as they are.
    func bloom() {}
}
