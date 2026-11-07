import AppKit
import QuartzCore
import SwiftUI

/// Shared animation curves and helpers, so everything in Margin moves the same way.
enum Motion {
    /// Quick start, soft landing. Used for most movement.
    static let easeOut = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
    static let easeInOut = CAMediaTimingFunction(controlPoints: 0.45, 0.0, 0.25, 1.0)
    static let easeIn = CAMediaTimingFunction(controlPoints: 0.4, 0.0, 0.9, 0.6)

    // SwiftUI animation tokens (Instrument). Wrap in `Motion.animation(_:)` so Reduce Motion drops to a short fade.
    /// Functional UI: 0.3 s, no bounce. Small UI (hover, press, toggles): 0.2 s. Exits run at about 65% of the enter time.
    static let functional = Animation.spring(duration: 0.3, bounce: 0)
    static let small = Animation.spring(duration: 0.2, bounce: 0)
    static let exit = Animation.spring(duration: 0.3 * 0.65, bounce: 0)
    static let exitSmall = Animation.spring(duration: 0.2 * 0.65, bounce: 0)
    /// Button press: scale 0.97.
    static let pressScale: CGFloat = 0.97
    // Older names, now aliases of the two durations above.
    static let snappy = functional
    static let smooth = functional
    static let quick = small
    /// `a`, or a 0.12 s ease-out when Reduce Motion is on (pair with opacity-only changes).
    static func animation(_ a: Animation) -> Animation { reduceMotion ? .easeOut(duration: 0.12) : a }

    /// Reduce Motion is on: movement and scale are dropped, opacity and colour changes stay.
    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Set by the headless picture harness (`--uishots`): every animation is drawn at its final frame.
    nonisolated(unsafe) static var still = false

    /// CASpringAnimation's stiffness / damping for a SwiftUI-style spring (mass 1): `response` is the period in seconds,
    /// `dampingFraction` 1 is critically damped.
    static func spring(response: CGFloat, damping fraction: CGFloat) -> (stiffness: CGFloat, damping: CGFloat) {
        let stiffness = pow(2 * .pi / response, 2)
        return (stiffness, 2 * fraction * stiffness.squareRoot())
    }

    /// A point on screen as a point in `view`'s layer, clamped to the view (so a point just outside it becomes its nearest edge).
    static func layerPoint(fromScreen p: NSPoint, in view: NSView) -> CGPoint? {
        guard let window = view.window, let layer = view.layer else { return nil }
        let local = view.convert(window.convertPoint(fromScreen: p), from: nil)
        let b = view.bounds
        let x = min(max(local.x, b.minX), b.maxX), y = min(max(local.y, b.minY), b.maxY)
        return CGPoint(x: x, y: view.isFlipped == layer.isGeometryFlipped ? y : b.maxY - (y - b.minY))
    }

    /// A transform that scales a layer around its center (view-backed layers anchor at a corner), or around `about`
    /// (a point in the layer's bounds) so it grows out of that point.
    static func scale(_ s: CGFloat, _ layer: CALayer, dy: CGFloat = 0, about: CGPoint? = nil) -> CATransform3D {
        let b = layer.bounds
        let anchor = CGPoint(x: b.minX + layer.anchorPoint.x * b.width, y: b.minY + layer.anchorPoint.y * b.height)
        let pivot = about ?? CGPoint(x: b.midX, y: b.midY)
        let tx = (1 - s) * (pivot.x - anchor.x)
        let ty = (1 - s) * (pivot.y - anchor.y) + dy
        return CATransform3DConcat(CATransform3DMakeScale(s, s, 1), CATransform3DMakeTranslation(tx, ty, 0))
    }

    /// Springs a view from `from` scale up to normal size, growing out of `about`, with a SwiftUI-style spring.
    /// Skipped under Reduce Motion (the caller's opacity fade is what remains).
    static func popIn(_ view: NSView, from s: CGFloat, about: CGPoint? = nil, response: CGFloat, damping fraction: CGFloat) {
        guard !reduceMotion, !still else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let params = spring(response: response, damping: fraction)
        let anim = CASpringAnimation(keyPath: "transform")
        anim.fromValue = scale(s, layer, about: about)
        anim.toValue = CATransform3DIdentity
        anim.damping = params.damping
        anim.stiffness = params.stiffness
        anim.mass = 1
        anim.duration = anim.settlingDuration
        layer.add(anim, forKey: "pop")
    }

    /// Springs a view from `from` scale up to normal size. Presentation-only: the model stays identity,
    /// so AppKit layout never fights it.
    static func popIn(_ view: NSView, from s: CGFloat, dy: CGFloat = 0,
                      damping: CGFloat = 16, stiffness: CGFloat = 260) {
        guard !reduceMotion, !still else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = scale(s, layer, dy: dy)
        spring.toValue = CATransform3DIdentity
        spring.damping = damping
        spring.stiffness = stiffness
        spring.mass = 1
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    /// Shrinks a view slightly as it fades out. Call `reset` after the window is ordered out.
    static func shrinkOut(_ view: NSView, to s: CGFloat, duration: CFTimeInterval) {
        guard !reduceMotion else { return }
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let shrink = CABasicAnimation(keyPath: "transform")
        shrink.fromValue = CATransform3DIdentity
        shrink.toValue = scale(s, layer)
        shrink.duration = duration
        shrink.timingFunction = easeIn
        shrink.fillMode = .forwards
        shrink.isRemovedOnCompletion = false
        layer.add(shrink, forKey: "pop")
    }

    static func reset(_ view: NSView) {
        view.layer?.removeAnimation(forKey: "pop")
    }
}

/// A snapshot of a window that can be held in place and then flown / morphed on the GPU.
/// Used for minimize, expand and resize, so the real window never animates with live content inside.
final class Ghost {
    private let window: FloatingPanel
    private let area: NSRect
    private let base: CALayer

    /// Shows `image` at `frame` right away. `area` must cover everywhere the ghost will travel.
    init(image: CGImage, frame: NSRect, radius: CGFloat, opacity: Float = 1,
         gravity: CALayerContentsGravity = .resizeAspectFill, background: NSColor? = nil, area: NSRect) {
        self.area = area
        window = FloatingPanel(size: area.size, canKey: false)
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.setFrame(area, display: false)
        let host = NSView(frame: NSRect(origin: .zero, size: area.size))
        host.wantsLayer = true
        window.contentView = host

        base = Self.imageLayer(image, gravity: gravity, background: background, scale: window.backingScaleFactor)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = Self.local(frame, in: area)
        base.cornerRadius = radius
        base.opacity = opacity
        host.layer?.addSublayer(base)
        CATransaction.commit()
        window.orderFrontRegardless()
    }

    /// One-shot flight between two rects (minimize / expand).
    static func fly(_ image: CGImage, from: NSRect, to: NSRect,
                    fromRadius: CGFloat, toRadius: CGFloat,
                    fromOpacity: Float = 1, toOpacity: Float = 1,
                    duration: CFTimeInterval, timing: CAMediaTimingFunction,
                    completion: @escaping (_ remove: @escaping () -> Void) -> Void) {
        let ghost = Ghost(image: image, frame: from, radius: fromRadius, opacity: fromOpacity,
                          area: from.union(to).insetBy(dx: -30, dy: -30))
        ghost.animate(to: to, radius: toRadius, opacity: toOpacity, duration: duration, timing: timing,
                      completion: completion)
    }

    /// Animates to `frame`. With `crossfadeTo`, the new image fades in over the old one on the way.
    /// `completion` gets a `remove` closure, so the caller can fade the real window in first.
    func animate(to frame: NSRect, radius: CGFloat, opacity: Float = 1,
                 crossfadeTo newImage: CGImage? = nil, gravity: CALayerContentsGravity = .resizeAspectFill,
                 background: NSColor? = nil,
                 duration: CFTimeInterval, timing: CAMediaTimingFunction,
                 completion: @escaping (_ remove: @escaping () -> Void) -> Void) {
        let end = Self.local(frame, in: area)
        var incoming: CALayer?
        if let newImage {
            let layer = Self.imageLayer(newImage, gravity: gravity, background: background,
                                        scale: window.backingScaleFactor)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.frame = base.frame
            layer.cornerRadius = base.cornerRadius
            layer.opacity = 0
            base.superlayer?.addSublayer(layer)
            CATransaction.commit()
            incoming = layer
        }

        // Remember where each layer starts, jump the model to the end state, then animate from the start.
        let layers = [base] + (incoming.map { [$0] } ?? [])
        let starts = layers.map { (position: $0.position, bounds: $0.bounds, radius: $0.cornerRadius, opacity: $0.opacity) }
        let endOpacities: [Float] = incoming == nil ? [opacity] : [0, opacity]
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, layer) in layers.enumerated() {
            layer.frame = end
            layer.cornerRadius = radius
            layer.opacity = endOpacities[i]
        }
        CATransaction.commit()

        let window = self.window
        CATransaction.begin()
        CATransaction.setCompletionBlock { completion { window.orderOut(nil) } }
        for (i, layer) in layers.enumerated() {
            let start = starts[i]
            let anims: [CABasicAnimation] = [
                Self.anim("position", from: NSValue(point: start.position)),
                Self.anim("bounds", from: NSValue(rect: start.bounds)),
                Self.anim("cornerRadius", from: start.radius),
                Self.anim("opacity", from: start.opacity),
            ]
            for a in anims {
                a.duration = duration
                a.timingFunction = timing
                layer.add(a, forKey: a.keyPath)
            }
        }
        CATransaction.commit()
    }

    /// Removes the ghost immediately (e.g. its window closed mid-animation).
    func dismiss() { window.orderOut(nil) }

    private static func anim(_ keyPath: String, from: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        return a
    }

    private static func imageLayer(_ image: CGImage, gravity: CALayerContentsGravity,
                                   background: NSColor?, scale: CGFloat) -> CALayer {
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = gravity
        layer.contentsScale = scale
        layer.masksToBounds = true
        layer.backgroundColor = background?.cgColor
        return layer
    }

    private static func local(_ r: NSRect, in area: NSRect) -> CGRect {
        CGRect(x: r.minX - area.minX, y: r.minY - area.minY, width: r.width, height: r.height)
    }
}


/// Smooth window resizing, driven by a plain timer. (The system's `animator().setFrame` was seen to stall until the next
/// animation started, which left the agent bar too narrow for its cats; a timer always finishes, and always ends exactly
/// on the target.)
enum WindowMotion {
    private static var timers: [ObjectIdentifier: Timer] = [:]

    static func animate(_ window: NSWindow, to target: NSRect, duration: TimeInterval = 0.2, completion: (() -> Void)? = nil) {
        let key = ObjectIdentifier(window)
        timers[key]?.invalidate()
        let start = window.frame
        guard start != target, window.isVisible, duration > 0 else {
            window.setFrame(target, display: true)
            timers[key] = nil
            completion?()
            return
        }
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak window] timer in
            guard let window else { return timer.invalidate() }
            let p = min(1, (CACurrentMediaTime() - began) / duration)
            let e = 1 - pow(1 - p, 3) // ease out
            if p >= 1 {
                timer.invalidate()
                timers[key] = nil
                window.setFrame(target, display: true)
                completion?()
                return
            }
            func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * CGFloat(e) }
            window.setFrame(NSRect(x: mix(start.minX, target.minX), y: mix(start.minY, target.minY),
                                   width: mix(start.width, target.width), height: mix(start.height, target.height)), display: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[key] = timer
    }
}
