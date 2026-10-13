import AppKit

enum Theme {
    /// Claude-ish terracotta.
    static let accent = NSColor(srgbRed: 0.85, green: 0.47, blue: 0.34, alpha: 1)
    /// Warm off-white behind the spark.
    static let ivory = NSColor(srgbRed: 0.96, green: 0.945, blue: 0.918, alpha: 1)

    /// Stretchable rounded-rect mask for NSVisualEffectView (clips the blur, not just the content).
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// Borderless panel that floats above everything and never activates Margin.
class FloatingPanel: NSPanel {
    init(size: NSSize, canKey: Bool) {
        self.canKey = canKey
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    private let canKey: Bool
    override var canBecomeKey: Bool { canKey }
    override var canBecomeMain: Bool { false }

    /// macOS nudges windows that poke above the menu bar back down. Turn that off for windows that are
    /// meant to overhang (the aura around a corner circle), or they slide off-center.
    var keepsBelowMenuBar = true
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        keepsBelowMenuBar ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }
}

/// The little spark bubble that appears next to a fresh selection.
final class TriggerIcon {
    var onClick: ((Selection, NSRect) -> Void)?

    private let size: CGFloat = 30
    private lazy var panel: FloatingPanel = {
        let p = FloatingPanel(size: NSSize(width: size, height: size), canKey: false)
        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: size, height: size))
        view.onClick = { [weak self] in self?.clicked() }
        p.contentView = view
        return p
    }()
    private var selection: Selection?
    private var hideTimer: Timer?
    private var showGeneration = 0

    func show(_ selection: Selection, at mouse: NSPoint) {
        self.selection = selection
        showGeneration += 1
        var origin = NSPoint(x: mouse.x + 8, y: mouse.y - 8 - size)
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) {
            let vf = screen.visibleFrame
            origin.x = min(max(origin.x, vf.minX + 4), vf.maxX - size - 4)
            origin.y = min(max(origin.y, vf.minY + 4), vf.maxY - size - 4)
        }
        panel.setFrameOrigin(origin)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
        if let view = panel.contentView {
            Motion.reset(view)
            Motion.popIn(view, from: 0.5, damping: 13, stiffness: 320)
        }
        scheduleHide(after: 3)
    }

    func hide() {
        hideTimer?.invalidate()
        guard panel.isVisible else { return }
        let gen = showGeneration
        if let view = panel.contentView { Motion.shrinkOut(view, to: 0.6, duration: 0.15) }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            ctx.timingFunction = Motion.easeIn
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, gen == self.showGeneration else { return }
            self.panel.orderOut(nil)
            if let view = self.panel.contentView { Motion.reset(view) }
        })
        selection = nil
    }

    private func scheduleHide(after seconds: TimeInterval) {
        hideTimer?.invalidate()
        hideTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            if NSMouseInRect(NSEvent.mouseLocation, self.panel.frame, false) {
                self.scheduleHide(after: 1) // hovering: keep it around
            } else {
                self.hide()
            }
        }
    }

    /// For `--demo`: the button rendered on its own, over a mid-gray backdrop.
    static func debugRender() -> NSBitmapImageRep? {
        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        let window = FloatingPanel(size: view.frame.size, canKey: false)
        window.contentView = view
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        defer { window.orderOut(nil) }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 120, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        rep.size = NSSize(width: 30, height: 30)
        ctx.scaleBy(x: 4, y: 4)
        ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return rep }
        view.cacheDisplay(in: view.bounds, to: cached)
        if let image = cached.cgImage { ctx.draw(image, in: CGRect(x: 0, y: 0, width: 30, height: 30)) }
        return rep
    }

    private func clicked() {
        guard let selection else { return }
        let frame = panel.frame
        hideTimer?.invalidate()
        showGeneration += 1
        panel.orderOut(nil)
        self.selection = nil
        onClick?(selection, frame)
    }
}

/// Ivory disc with a terracotta spark. On hover the spark turns a little and the disc brightens.
private final class BubbleView: NSView {
    var onClick: (() -> Void)?

    private let host = NSView()
    private let disc = CAShapeLayer()
    private let spark: CAShapeLayer

    override init(frame: NSRect) {
        let discRect = CGRect(origin: .zero, size: frame.size).insetBy(dx: 2, dy: 2)
        spark = ClaudeMark.layer(in: discRect.insetBy(dx: discRect.width * 0.2, dy: discRect.height * 0.2),
                                 color: Theme.accent)
        super.init(frame: frame)
        wantsLayer = true
        host.frame = bounds
        host.wantsLayer = true
        disc.path = CGPath(ellipseIn: discRect, transform: nil)
        disc.fillColor = Theme.ivory.cgColor
        disc.strokeColor = NSColor.black.withAlphaComponent(0.14).cgColor
        disc.lineWidth = 0.5
        host.layer?.addSublayer(disc)
        host.layer?.addSublayer(spark)
        addSubview(host)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = "Ask Claude about this"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private func setHover(_ on: Bool) {
        let target = on
            ? CATransform3DConcat(CATransform3DMakeRotation(-.pi / 6, 0, 0, 1), CATransform3DMakeScale(1.14, 1.14, 1))
            : CATransform3DIdentity
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = (spark.presentation() ?? spark).transform
        spring.toValue = target
        spring.damping = 12
        spring.stiffness = 260
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        spark.transform = target
        CATransaction.commit()
        spark.add(spring, forKey: "hover")
        disc.fillColor = (on ? NSColor.white : Theme.ivory).cgColor // implicit fade
    }
}
