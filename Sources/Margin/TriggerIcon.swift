import AppKit

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
            Motion.popIn(view, from: 0.8, response: 0.32, damping: 0.7) // springs in with a little overshoot; never from 0
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

    /// For `--uishots`: the button drawn without a window, at 4×.
    @MainActor
    static func shotImage() -> CGImage? {
        let view = BubbleView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        view.layoutSubtreeIfNeeded()
        view.appearance = NSAppearance.currentDrawing()
        return view.snapshotRep()?.cgImage
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
        guard let rep = NSBitmapImageRep.rgba(pixelsWide: 120, pixelsHigh: 120),
              let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        rep.size = NSSize(width: 30, height: 30)
        ctx.scaleBy(x: 4, y: 4)
        ctx.setFillColor(NSColor(white: 0.45, alpha: 1).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 30, height: 30))
        guard let cached = view.snapshotRep() else { return rep }
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

/// An accent rounded square with a dark spark. On hover the spark turns a little and the square brightens.
private final class BubbleView: FirstMouseView {
    var onClick: (() -> Void)?

    private let host = NSView()
    /// A plain layer holding the picture, so hover / press scaling is not fought by AppKit's own layer for the view.
    private let scaler = CALayer()
    private let disc = CAShapeLayer()
    private let spark: CAShapeLayer

    override init(frame: NSRect) {
        let discRect = CGRect(origin: .zero, size: frame.size).insetBy(dx: 2, dy: 2)
        spark = ClaudeMark.layer(in: discRect.insetBy(dx: discRect.width * 0.2, dy: discRect.height * 0.2),
                                 color: Theme.onAccent.ns)
        super.init(frame: frame)
        wantsLayer = true
        host.frame = bounds
        host.wantsLayer = true
        disc.path = CGPath(roundedRect: discRect, cornerWidth: 6, cornerHeight: 6, transform: nil)
        disc.fillColor = Theme.accent.ns.cgColor
        disc.strokeColor = Theme.onAccent.ns.withAlphaComponent(0.18).cgColor
        disc.lineWidth = 0.5
        scaler.frame = host.bounds
        host.layer?.addSublayer(scaler)
        scaler.addSublayer(disc)
        scaler.addSublayer(spark)
        addSubview(host)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
        toolTip = "Ask Claude about this"
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Layers keep the colours they were given, so a light/dark switch recolours them here.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            disc.fillColor = Theme.accent.ns.cgColor
            disc.strokeColor = Theme.onAccent.ns.withAlphaComponent(0.18).cgColor
            spark.strokeColor = Theme.onAccent.ns.cgColor
        }
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    override func mouseDown(with event: NSEvent) { pressed = true; settleScale() }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        settleScale()
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }

    private var hovering = false
    private var pressed = false

    /// The whole button: 1.06 under the pointer, 0.94 while pressed (a small spring; nothing without Reduce Motion off).
    private func settleScale() {
        guard !Motion.reduceMotion else { return }
        let layer = scaler
        let target: CGFloat = pressed ? 0.94 : (hovering ? 1.06 : 1)
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = (layer.presentation() ?? layer).transform
        spring.toValue = Motion.scale(target, layer)
        let params = Motion.spring(response: 0.22, damping: 0.86)
        spring.stiffness = params.stiffness
        spring.damping = params.damping
        spring.duration = spring.settlingDuration
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = Motion.scale(target, layer)
        CATransaction.commit()
        layer.add(spring, forKey: "press")
    }

    private func setHover(_ on: Bool) {
        hovering = on
        settleScale()
        guard !Motion.reduceMotion else {
            disc.fillColor = (on ? (Theme.accent.ns.highlight(withLevel: 0.35) ?? Theme.accent.ns) : Theme.accent.ns).cgColor
            return
        }
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
        disc.fillColor = (on ? (Theme.accent.ns.highlight(withLevel: 0.35) ?? Theme.accent.ns) : Theme.accent.ns).cgColor // implicit fade
    }
}

extension NSPanel {
    /// For tests: a press at `local` (panel coordinates), a six-step drag by `delta` and a release, as real mouse events.
    func debugPlayDrag(from local: NSPoint, by delta: NSSize) {
        let start = NSPoint(x: frame.minX + local.x, y: frame.minY + local.y)
        func send(_ type: NSEvent.EventType, at screen: NSPoint) {
            let location = NSPoint(x: screen.x - frame.minX, y: screen.y - frame.minY)
            guard let e = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            sendEvent(e)
        }
        send(.leftMouseDown, at: start)
        for i in 1...6 {
            let f = CGFloat(i) / 6
            send(.leftMouseDragged, at: NSPoint(x: start.x + delta.width * f, y: start.y + delta.height * f))
        }
        send(.leftMouseUp, at: NSPoint(x: start.x + delta.width, y: start.y + delta.height))
    }
}
