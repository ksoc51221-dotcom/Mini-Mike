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
    /// The timer runs at the screen's rate only while the chat is changing. A chat that sits still for `settle` seconds is
    /// checked a few times a second instead (an open chat used to wake the Mac 60 times a second all day).
    private var fast = false
    private var lastChange = Date.distantPast
    private var watchers: [NSKeyValueObservation] = []
    private var notes: [NSObjectProtocol] = []
    static let settle: TimeInterval = 1
    static let idleInterval: TimeInterval = 0.1

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
        guard let panel else { return }
        watch(panel) // even if the chat isn't on screen yet: the first tick settles it, as before
        lastChange = Date()
        run(fast: true)
    }

    /// The timer holds the glow until its window is gone, even if the chat that owns it is released
    /// first (closing a chat drops it right away). Otherwise the glow would be stranded on screen.
    private func run(fast: Bool) {
        if timer != nil, self.fast == fast { return }
        timer?.invalidate()
        self.fast = fast
        let t = Timer(timeInterval: fast ? 1.0 / 60 : Self.idleInterval, repeats: true) { _ in self.tick() }
        if !fast { t.tolerance = Self.idleInterval / 2 }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let changed = follow()
        guard timer != nil else { return } // the chat went away
        if changed {
            lastChange = Date()
            run(fast: true)
        } else if fast, Date().timeIntervalSince(lastChange) > Self.settle {
            run(fast: false)
        }
    }

    /// The chat moved, resized, faded or hid: follow at once, and at the screen's rate while it keeps changing.
    private func poke() {
        guard timer != nil else { return }
        follow()
        guard timer != nil else { return }
        lastChange = Date()
        run(fast: true)
    }

    private func watch(_ panel: NSWindow) {
        guard watchers.isEmpty else { return }
        watchers = [
            panel.observe(\.alphaValue) { [weak self] _, _ in self?.poke() },
            panel.observe(\.isVisible) { [weak self] _, _ in self?.poke() },
        ]
        let center = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.willCloseNotification] {
            notes.append(center.addObserver(forName: name, object: panel, queue: nil) { [weak self] _ in self?.poke() })
        }
    }

    /// The chat came to the front (you clicked it among several): its glow goes back to sitting right behind it.
    func restack() {
        guard let panel, panel.isVisible, window.isVisible else { return }
        window.order(.below, relativeTo: panel.windowNumber)
    }

    func remove() {
        timer?.invalidate()
        timer = nil
        watchers.forEach { $0.invalidate() }
        watchers = []
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        notes = []
        window.orderOut(nil)
    }

    deinit {
        notes.forEach { NotificationCenter.default.removeObserver($0) }
        window.orderOut(nil)
    }

    /// Glow windows still on screen (for --glowtest: none should outlive their chat).
    static var visibleWindowCount: Int { NSApp.windows.filter { $0 is GlowWindow && $0.isVisible }.count }

    /// Matches the chat's frame and fade. Stops by itself once the chat is off screen. Returns whether anything had to change.
    @discardableResult
    private func follow() -> Bool {
        guard let panel, panel.isVisible else { remove(); return false }
        var changed = false
        let frame = panel.frame.insetBy(dx: -Self.reach, dy: -Self.reach)
        if window.frame != frame { window.setFrame(frame, display: true); changed = true }
        if window.alphaValue != panel.alphaValue { window.alphaValue = panel.alphaValue; changed = true }
        if !window.isVisible || window.level != panel.level {
            window.level = panel.level
            window.order(.below, relativeTo: panel.windowNumber)
            changed = true
        }
        return changed
    }

    // For --glowtest and the unit checks.
    var debugFrame: NSRect { window.frame }
    var debugVisible: Bool { window.isVisible }
    var debugIdle: Bool { timer != nil && !fast }
    var debugStopped: Bool { timer == nil }
    /// The glow as it looks right now, with `chat` (a snapshot of the chat) drawn over it, on a dark backdrop.
    func debugImage(chat: CGImage?) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep.rgba(pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2)) else { return nil }
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
