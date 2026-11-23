import AppKit

/// Point to ask: hold Shift on its own, move the pointer over what you want explained, let go to ask about it.
///
/// `Hotkeys` decides when it starts, ends or is cancelled (see `ModifierHold`); this draws the trail while you point and
/// works out which part of the screen to take. The picture itself goes through the snip path (`Snipper.run(rect:)`).
/// All positions here are screen points with a top-left origin, the way event taps and `screencapture -R` count them.
final class PointToAsk {
    /// The pointer's path so far.
    private(set) var trail: [CGPoint] = []
    private var overlay: TrailOverlay?

    var isActive: Bool { !trail.isEmpty }

    /// The trail window's number, so the capture can wait until the window server has really taken it off the screen.
    var overlayWindowNumber: Int? { overlay.map(\.windowNumber).flatMap { $0 > 0 ? $0 : nil } }

    func begin(from start: CGPoint, to point: CGPoint) {
        trail = [start, point]
        let window = overlay ?? TrailOverlay()
        overlay = window
        window.show(on: PointGeometry.screen(containing: start), trail: trail)
    }

    func move(to point: CGPoint) {
        guard isActive else { return }
        trail.append(point)
        overlay?.update(trail)
    }

    func cancel() {
        trail = []
        overlay?.hide(animated: true)
    }

    /// Hides the trail at once (so it isn't in the picture) and returns the area to take, or nil.
    func end() -> CGRect? {
        defer { trail = [] }
        overlay?.hide(animated: false)
        return PointGeometry.captureRect(trail: trail, screens: PointGeometry.screenFrames())
    }
}

/// The sums behind point to ask, kept apart so the tests can check them without a screen.
enum PointGeometry {
    /// Space around the trail, so what you pointed at isn't cut at its edge.
    static let margin: CGFloat = 24

    /// The trail's bounding box plus `margin` on every side, kept inside the screen the trail ended on. Nil for no trail
    /// or nothing left after clamping.
    static func captureRect(trail: [CGPoint], margin: CGFloat = margin, screens: [CGRect]) -> CGRect? {
        guard let first = trail.first else { return nil }
        var box = CGRect(origin: first, size: .zero)
        for p in trail.dropFirst() { box = box.union(CGRect(origin: p, size: .zero)) }
        box = box.insetBy(dx: -margin, dy: -margin)
        let last = trail.last ?? first
        let screen = screens.first { $0.contains(last) }
            ?? screens.max { $0.intersection(box).area < $1.intersection(box).area }
        guard let screen else { return nil }
        let clamped = box.intersection(screen)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// A top-left-origin point as AppKit counts it (bottom-left origin, measured from the main screen).
    static func toAppKit(_ p: CGPoint, mainHeight: CGFloat) -> CGPoint { CGPoint(x: p.x, y: mainHeight - p.y) }

    /// An AppKit screen frame with a top-left origin.
    static func topLeftFrame(_ frame: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: frame.minX, y: mainHeight - frame.maxY, width: frame.width, height: frame.height)
    }

    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func screenFrames() -> [CGRect] { NSScreen.screens.map { topLeftFrame($0.frame, mainHeight: mainHeight) } }

    static func screen(containing p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { topLeftFrame($0.frame, mainHeight: mainHeight).contains(p) } ?? NSScreen.main
    }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

/// The soft trail: a clear, click-through window over one screen that never takes focus.
private final class TrailOverlay: NSPanel {
    private let trailView = TrailView()
    /// Bumped on every show, so a fade-out that finishes late never hides a newer trail.
    private var generation = 0

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isReleasedWhenClosed = false
        contentView = trailView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var still: Bool { Motion.reduceMotion || Motion.still }

    func show(on screen: NSScreen?, trail: [CGPoint]) {
        guard let screen else { return }
        generation += 1
        setFrame(screen.frame, display: false)
        update(trail)
        alphaValue = still ? 1 : 0 // (also undoes the 0 left by a hide-for-capture)
        orderFrontRegardless()
        if !still {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = 1
            }
        }
    }

    func update(_ trail: [CGPoint]) {
        let h = PointGeometry.mainHeight
        let origin = frame.origin
        trailView.points = trail.map {
            let p = PointGeometry.toAppKit($0, mainHeight: h)
            return CGPoint(x: p.x - origin.x, y: p.y - origin.y)
        }
    }

    func hide(animated: Bool) {
        guard animated, !still else {
            // About to be photographed: wipe the trail, then take the window off, and push both to the window server now
            // (it would otherwise go at the end of this turn of the run loop, after the capture has been started).
            generation += 1 // a fade-out still running must not put anything back
            trailView.points = []
            trailView.displayIfNeeded()
            alphaValue = 0
            orderOut(nil)
            CATransaction.flush()
            return
        }
        let shown = generation
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.generation == shown else { return }
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }
}

private final class TrailView: NSView {
    var points: [CGPoint] = [] { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard points.count > 1 else { return }
        let path = NSBezierPath()
        path.move(to: points[0])
        for p in points.dropFirst() { path.line(to: p) }
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 14
        Theme.accent.ns.withAlphaComponent(0.28).setStroke()
        path.stroke()
    }
}

// MARK: - The real-screen check (`--trailcheck`)

extension PointToAsk {
    /// Only for `--trailcheck`: the hide as it was before the fix (take the window off, nothing else).
    fileprivate func oldHide() { overlay?.orderOut(nil); trail = [] }

    /// Draws a trail on the real screen twice (about 4 seconds in all) and photographs that area, the way the app does
    /// (the capture is started and the main thread carries on):
    /// 1. with the trail up: the control. The pictures must be able to see the trail, or nothing below means anything;
    /// 2. the OLD way: plain hide, capture started at once. If the trail is in this picture, that was the fault;
    /// 3. the NEW way: `end()`, then the gate, then the capture. The trail must not be in this one.
    /// Each is compared with a picture taken a second later, when the trail is certainly gone. Needs Screen Recording permission.
    static func liveTrailCheck() -> Never {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let start = CGPoint(x: 240, y: 260)
        let path = stride(from: 0, through: 320, by: 8).map { CGPoint(x: start.x + CGFloat($0), y: start.y + 40 * sin(CGFloat($0) / 40)) }
        guard let rect = PointGeometry.captureRect(trail: path, screens: PointGeometry.screenFrames()) else { print("TRAILCHECK FAIL: no area"); exit(1) }
        // A plain grey card under the trail, so nothing else on the screen (a video, a chat that is still writing) changes
        // between the pictures. It sits below the trail's window.
        let h = PointGeometry.mainHeight
        let backdrop = NSPanel(contentRect: NSRect(x: rect.minX - 8, y: h - rect.maxY - 8, width: rect.width + 16, height: rect.height + 16),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        backdrop.backgroundColor = NSColor(white: 0.5, alpha: 1)
        backdrop.isOpaque = true
        backdrop.hasShadow = false
        backdrop.ignoresMouseEvents = true
        backdrop.level = .floating
        backdrop.orderFrontRegardless()
        let pointer = PointToAsk()
        func draw() {
            pointer.begin(from: start, to: path[1])
            path.dropFirst(2).forEach { pointer.move(to: $0) }
        }
        func capture(_ then: @escaping (NSBitmapImageRep?) -> Void) {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-trailcheck-\(UUID().uuidString).png")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            let r = rect.integral
            p.arguments = ["-x", "-R\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))", url.path]
            p.terminationHandler = { _ in
                DispatchQueue.main.async {
                    let rep = (try? Data(contentsOf: url)).flatMap(NSBitmapImageRep.init(data:))
                    try? FileManager.default.removeItem(at: url)
                    then(rep)
                }
            }
            do { try p.run() } catch { then(nil) }
        }
        /// How many pixels differ clearly between two pictures of the same area.
        func difference(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?) -> Int {
            guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return -1 }
            var n = 0
            for y in stride(from: 0, to: a.pixelsHigh, by: 2) {
                for x in stride(from: 0, to: a.pixelsWide, by: 2) {
                    guard let p = a.colorAt(x: x, y: y), let q = b.colorAt(x: x, y: y) else { continue }
                    if abs(p.redComponent - q.redComponent) + abs(p.greenComponent - q.greenComponent) + abs(p.blueComponent - q.blueComponent) > 0.12 { n += 1 }
                }
            }
            return n
        }
        func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work) }

        draw()
        after(0.5) {
            capture { withTrail in
                pointer.oldHide()
                capture { oldWay in // started in the same turn as the hide, as the app did
                    after(1) {
                        capture { clean in
                            let seen = difference(withTrail, clean), oldLeft = difference(oldWay, clean)
                            draw()
                            after(0.5) {
                                _ = pointer.end()
                                let number = pointer.overlayWindowNumber // read after `end()`, as `finishPoint` does
                                let listed = number.map(WindowGate.isOnScreen) ?? false
                                WindowGate.wait(until: { !(number.map(WindowGate.isOnScreen) ?? false) }) { waited, timedOut in
                                    capture { newWay in
                                        after(1) {
                                            capture { clean2 in
                                                let newLeft = difference(newWay, clean2)
                                                print("1. control: pixels that show the trail while it is up = \(seen)")
                                                print("2. old way (hide, capture at once): trail pixels left in the picture = \(oldLeft)")
                                                print("3. new way: window number known=\(number != nil), still listed right after hide=\(listed), gate waited \(Int(waited * 1000)) ms, gave up=\(timedOut); trail pixels left = \(newLeft)")
                                                if seen < 50 {
                                                    print("TRAILCHECK INCONCLUSIVE: the pictures can't see the trail at all (no Screen Recording permission for this binary?)")
                                                    exit(2)
                                                }
                                                print(oldLeft > max(5, seen / 100) ? "CAUSE PROVEN: the old hide left the trail in the picture" : "CAUSE NOT REPRODUCED: the old hide gave a clean picture here")
                                                let ok = number != nil && !timedOut && newLeft >= 0 && newLeft <= max(5, seen / 100)
                                                print(ok ? "TRAILCHECK PASS" : "TRAILCHECK FAIL")
                                                exit(ok ? 0 : 1)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        RunLoop.main.run()
        exit(1)
    }
}
