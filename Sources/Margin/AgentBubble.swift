import AppKit

/// The look of an agent's circle in the sidebar: working is light purple, done is dark green, failed is red.
enum AgentBubble {
    static let lightPurple = NSColor(srgbRed: 0.79, green: 0.66, blue: 1.00, alpha: 1) // #C9A8FF
    static let darkGreen = NSColor(srgbRed: 0.05, green: 0.48, blue: 0.21, alpha: 1)   // #0D7A36
    static let errorRed = NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: 1)

    static func color(for phase: AgentPhase) -> NSColor {
        switch phase {
        case .idle, .working: return lightPurple
        case .done: return darkGreen
        case .failed: return errorRed
        }
    }
}

// MARK: - Aura

/// The glow around a circle: a soft radial bloom that breathes, and rings that ripple outward.
final class GlowView: NSView {
    private let diameter: CGFloat
    private let reach: CGFloat
    private let host = NSView()
    private let bloom = CAGradientLayer()
    private var ripples: [CAShapeLayer] = []
    private var phase: AgentPhase?

    /// One ripple leaves every `period / 3` seconds and takes `period` to fade out.
    private let period: CFTimeInterval = 3.2

    private var radius: CGFloat { diameter / 2 }
    /// How far ripples travel before they've faded away.
    private var farthest: CGFloat { radius + reach * 0.95 }

    init(diameter: CGFloat, reach: CGFloat) {
        self.diameter = diameter
        self.reach = reach
        let side = diameter + reach * 2
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        host.frame = bounds
        host.wantsLayer = true
        addSubview(host)

        bloom.type = .radial
        bloom.frame = bounds
        bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
        bloom.endPoint = CGPoint(x: 1, y: 1)
        host.layer?.addSublayer(bloom)

        for _ in 0..<3 {
            let ring = CAShapeLayer()
            ring.frame = bounds
            ring.path = circle(radius)
            ring.fillColor = nil
            ring.lineWidth = 1.6
            ring.shadowOffset = .zero
            ring.shadowRadius = 7 // a soft halo, so ripples read as light rather than lines
            ring.shadowOpacity = 1
            ring.shadowPath = halo(radius, width: 2.5)
            ring.opacity = 0
            host.layer?.addSublayer(ring)
            ripples.append(ring)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // Ripples grow by animating their actual circle (not a scale transform), so the line stays
    // crisp and thin as it travels, and the glow outline travels with it.
    private func circle(_ r: CGFloat) -> CGPath {
        CGPath(ellipseIn: CGRect(x: bounds.midX - r, y: bounds.midY - r, width: r * 2, height: r * 2), transform: nil)
    }

    private func halo(_ r: CGFloat, width: CGFloat) -> CGPath {
        circle(r).copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    /// A ring traveling from the circle's edge out to `to`, thinning and fading as it goes.
    private func ripple(to r: CGFloat, startWidth: CGFloat, opacities: [Float], times: [NSNumber]) -> CAAnimationGroup {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = opacities
        fade.keyTimes = times
        let group = CAAnimationGroup()
        group.animations = [
            Self.basic("path", from: circle(radius), to: circle(r)),
            Self.basic("shadowPath", from: halo(radius, width: startWidth + 1), to: halo(r, width: 1.2)),
            Self.basic("lineWidth", from: startWidth, to: 0.6),
            fade,
        ]
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }

    func setPhase(_ newPhase: AgentPhase) {
        let color = AgentBubble.color(for: newPhase)
        let edge = radius / (bounds.width / 2) // where the circle's edge sits in the gradient
        bloom.colors = [0.85, 0.75, 0.32, 0.1, 0].map { color.withAlphaComponent($0).cgColor }
        bloom.locations = [0, edge, edge + (1 - edge) * 0.28, edge + (1 - edge) * 0.62, 1].map { NSNumber(value: Double($0)) }
        let rippleColor = (color.blended(withFraction: 0.35, of: .white) ?? color).cgColor
        for ring in ripples {
            ring.strokeColor = rippleColor
            ring.shadowColor = color.cgColor
        }

        guard newPhase != phase else { return }
        let previous = phase
        phase = newPhase
        bloom.removeAllAnimations()
        ripples.forEach { $0.removeAllAnimations() }

        switch newPhase {
        case .idle, .working:
            bloom.opacity = 1
            // The bloom breathes in and out…
            let breathe = CAAnimationGroup()
            breathe.animations = [
                Self.basic("opacity", from: 0.5, to: 1.0),
                Self.basic("endPoint", from: NSValue(point: CGPoint(x: 0.88, y: 0.88)),
                           to: NSValue(point: CGPoint(x: 1.0, y: 1.0))),
            ]
            breathe.duration = 1.6
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            bloom.add(breathe, forKey: "breathe")

            // …while rings slowly radiate outward and fade, one after another.
            for (i, ring) in ripples.enumerated() {
                let radiate = ripple(to: farthest, startWidth: 2.2, opacities: [0, 0.75, 0.3, 0], times: [0, 0.12, 0.5, 1])
                radiate.duration = period
                radiate.repeatCount = .infinity
                radiate.timeOffset = period * Double(i) / Double(ripples.count)
                ring.add(radiate, forKey: "radiate")
            }

        case .done, .failed:
            bloom.opacity = newPhase == .done ? 0.95 : 0.7
            // One bright burst outward to mark the moment it finished.
            if previous == .working || previous == .idle {
                let burst = ripple(to: farthest * 1.05, startWidth: 3.2, opacities: [1, 0.8, 0], times: [0, 0.3, 1])
                burst.duration = 1.4
                ripples[0].add(burst, forKey: "burst")

                let swell = CAKeyframeAnimation(keyPath: "endPoint")
                swell.values = [CGPoint(x: 1.12, y: 1.12), CGPoint(x: 0.97, y: 0.97), CGPoint(x: 1, y: 1)]
                    .map { NSValue(point: $0) }
                swell.keyTimes = [0, 0.6, 1]
                swell.duration = 1.0
                bloom.add(swell, forKey: "swell")
            }
        }
    }

    var debugRipples: String {
        ripples.map { ring -> String in
            String(format: "opacity %.2f", ring.presentation()?.opacity ?? -1)
        }.joined(separator: " | ")
    }

    fileprivate static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        return a
    }
}

// MARK: - Circle

final class DiscView: NSView {
    private let diameter: CGFloat
    private let pad: CGFloat
    private let layerHost = NSView()
    private let discLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    /// A point of light (with a faint tail) that orbits the ring while working.
    private let orbit = CALayer()
    private let comet = CAShapeLayer()
    private let tail = CAShapeLayer()
    /// The spark turns slowly while working.
    private let spark: CAShapeLayer
    /// Done: a crown of rounded spikes around the ring (long and short, like Claude's spark),
    /// and a dry-brush cream check that paints itself in.
    private let spikes = CAShapeLayer()
    private let check = CALayer()
    private let checkMask = CAShapeLayer()
    /// The ! when something went wrong.
    private let glyph = NSImageView()
    private var phase: AgentPhase?

    private var discRect: NSRect { bounds.insetBy(dx: pad, dy: pad) }

    init(diameter: CGFloat, pad: CGFloat) {
        self.diameter = diameter
        self.pad = pad
        let frame = NSRect(x: 0, y: 0, width: diameter + pad * 2, height: diameter + pad * 2)
        let disc = frame.insetBy(dx: pad, dy: pad)
        spark = ClaudeMark.layer(in: disc.insetBy(dx: diameter * 0.28, dy: diameter * 0.28), color: .white)
        super.init(frame: frame)
        wantsLayer = true

        layerHost.frame = bounds
        layerHost.wantsLayer = true
        discLayer.path = CGPath(ellipseIn: disc, transform: nil)
        discLayer.fillColor = NSColor(white: 0.09, alpha: 0.94).cgColor

        let ringPath = CGPath(ellipseIn: disc.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        ringLayer.path = ringPath
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 3
        ringLayer.shadowOffset = .zero
        ringLayer.shadowOpacity = 1
        ringLayer.shadowRadius = 9
        ringLayer.shadowPath = ringPath.copy(strokingWithWidth: 3, lineCap: .round, lineJoin: .round, miterLimit: 1)

        orbit.frame = disc
        let c = CGPoint(x: disc.width / 2, y: disc.height / 2), r = diameter / 2 - 1.5
        tail.path = Self.arc(center: c, radius: r, from: 40, to: 160)
        tail.lineWidth = 3
        tail.lineCap = .round
        tail.fillColor = nil
        tail.strokeColor = AgentBubble.lightPurple.withAlphaComponent(0.55).cgColor
        comet.path = Self.arc(center: c, radius: r, from: 40, to: 88)
        comet.lineWidth = 3.4
        comet.lineCap = .round
        comet.fillColor = nil
        comet.strokeColor = NSColor(srgbRed: 0.97, green: 0.94, blue: 1, alpha: 1).cgColor
        comet.shadowColor = AgentBubble.lightPurple.cgColor
        comet.shadowOffset = .zero
        comet.shadowRadius = 6
        comet.shadowOpacity = 1
        comet.shadowPath = comet.path?.copy(strokingWithWidth: 4, lineCap: .round, lineJoin: .round, miterLimit: 1)
        orbit.addSublayer(tail)
        orbit.addSublayer(comet)

        layerHost.layer?.addSublayer(discLayer)
        layerHost.layer?.addSublayer(ringLayer)
        layerHost.layer?.addSublayer(orbit)
        layerHost.layer?.addSublayer(spark)

        spikes.frame = bounds
        spikes.path = spikePath(grown: 1)
        spikes.lineWidth = 2.2
        spikes.lineCap = .round
        spikes.fillColor = nil
        spikes.strokeColor = AgentBubble.darkGreen.cgColor
        spikes.shadowColor = AgentBubble.darkGreen.cgColor
        spikes.shadowOffset = .zero
        spikes.shadowRadius = 5
        spikes.shadowOpacity = 0.9
        // The painted check, revealed by a mask that travels along the brush's path.
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        check.frame = disc
        check.contents = BrushCheck.image(side: disc.width, scale: scale, color: Theme.ivory)
        check.contentsScale = scale
        checkMask.frame = check.bounds
        checkMask.path = BrushCheck.centerline(in: check.bounds, overshoot: 0.12)
        checkMask.lineWidth = diameter * 0.22
        checkMask.lineCap = .round
        checkMask.lineJoin = .round
        checkMask.fillColor = nil
        checkMask.strokeColor = NSColor.black.cgColor
        check.mask = checkMask
        for layer in [spikes, check] {
            layer.isHidden = true
            layerHost.layer?.addSublayer(layer)
        }
        addSubview(layerHost)

        glyph.frame = disc.insetBy(dx: diameter * 0.27, dy: diameter * 0.27)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = .white
        glyph.isHidden = true
        addSubview(glyph)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setPhase(_ newPhase: AgentPhase) {
        let color = AgentBubble.color(for: newPhase)
        ringLayer.strokeColor = color.cgColor
        ringLayer.shadowColor = color.cgColor

        guard newPhase != phase else { return }
        phase = newPhase
        for layer in [ringLayer, orbit, spark, spikes, check, checkMask] { layer.removeAllAnimations() }

        let working = newPhase == .idle || newPhase == .working
        let done = newPhase == .done
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbit.isHidden = !working
        spark.isHidden = !working
        spikes.isHidden = !done
        check.isHidden = !done
        CATransaction.commit()
        glyph.isHidden = newPhase != .failed

        if working {
            // The ring pulses…
            let pulse = CAAnimationGroup()
            pulse.animations = [
                GlowView.basic("lineWidth", from: 2.4, to: 3.8),
                GlowView.basic("shadowRadius", from: 5, to: 13),
                GlowView.basic("shadowOpacity", from: 0.6, to: 1),
            ]
            pulse.duration = 0.8
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ringLayer.add(pulse, forKey: "pulse")
            // …a point of light circles it…
            let spin = GlowView.basic("transform.rotation.z", from: 0, to: -2 * Double.pi)
            spin.duration = 2.2
            spin.repeatCount = .infinity
            orbit.add(spin, forKey: "orbit")
            // …and the spark turns slowly in the middle.
            let turn = GlowView.basic("transform.rotation.z", from: 0, to: -2 * Double.pi)
            turn.duration = 9
            turn.repeatCount = .infinity
            spark.add(turn, forKey: "turn")
        } else {
            if done {
                celebrate()
            } else {
                glyph.image = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: diameter * 0.3, weight: .bold))
                Motion.popIn(glyph, from: 0.3, damping: 10, stiffness: 300)
            }
            let flash = GlowView.basic("shadowRadius", from: 22, to: 9)
            flash.duration = 0.9
            flash.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ringLayer.add(flash, forKey: "flash")
        }
    }

    /// The finish: spikes spring out of the ring and the check paints itself in.
    /// Also replayed whenever a finished circle reappears.
    func celebrate() {
        guard phase == .done else { return }
        let now = CACurrentMediaTime()

        let grow = CASpringAnimation(keyPath: "path")
        grow.fromValue = spikePath(grown: 0)
        grow.toValue = spikePath(grown: 1)
        grow.damping = 8
        grow.stiffness = 170
        grow.duration = grow.settlingDuration
        spikes.add(grow, forKey: "grow")
        let turn = GlowView.basic("transform.rotation.z", from: 0, to: -2 * Double.pi)
        turn.duration = 60 // barely moving, just alive
        turn.repeatCount = .infinity
        spikes.add(turn, forKey: "turn")

        let draw = GlowView.basic("strokeEnd", from: 0, to: 1)
        draw.duration = 0.45
        draw.beginTime = now + 0.12
        draw.fillMode = .backwards
        draw.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0, 0.2, 1)
        checkMask.add(draw, forKey: "draw")
    }

    /// Short rounded rays all around the ring, alternating long and short like Claude's spark.
    /// `grown` 0…1 animates them out of the ring.
    private func spikePath(grown g: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let inner = diameter / 2 + 0.5
        let longest = diameter * 0.15
        let count = 24
        for i in 0..<count {
            let jitter: CGFloat = i % 3 == 0 ? 0.04 : -0.02 // slightly hand-made, not machine-even
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi + jitter
            let length = longest * (i % 2 == 0 ? 1.0 : 0.5) * (0.82 + 0.18 * abs(sin(CGFloat(i) * 1.7)))
            let outer = inner + max(0.01, length * g)
            path.move(to: CGPoint(x: c.x + cos(a) * inner, y: c.y + sin(a) * inner))
            path.addLine(to: CGPoint(x: c.x + cos(a) * outer, y: c.y + sin(a) * outer))
        }
        return path
    }

    private static func arc(center: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: center, radius: radius,
                    startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
        return path
    }

    /// The circle only draws; the row it sits in takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
