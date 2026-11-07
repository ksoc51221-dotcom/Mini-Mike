import AppKit

/// The look of an agent's circle in the sidebar (an ink surface in both appearances): working is the accent,
/// done is the accent too (a check), failed is alert.
enum AgentBubble {
    static let working = Theme.accent.dark
    static let done = Theme.ink.dark // the accent is for live things only; done is plain ink
    static let failed = Theme.alert.dark

    static func color(for phase: AgentPhase) -> NSColor {
        switch phase {
        case .idle, .working: return working
        case .done: return done
        case .failed: return failed
        }
    }
}

// MARK: - Circle

/// The agent's circle: one 2 px ring, coloured by state, with no glow. Working: an accent arc sweeps round a dim track.
/// Done: an ink ring and a check that draws on. Failed: an alert ring and a "!" with a short shake.
final class DiscView: NSView {
    private let diameter: CGFloat
    private let pad: CGFloat
    private let layerHost = NSView()
    private let discLayer = CAShapeLayer()
    private let ringLayer = CAShapeLayer()
    /// The accent arc that sweeps round the ring while working.
    private let sweep = CAShapeLayer()
    /// The spark turns slowly while working.
    private let spark: CAShapeLayer
    /// Done: one stroke, drawn on by trimming its end from 0 to 1.
    private let check = CAShapeLayer()
    /// The ! when something went wrong.
    private let glyph = NSImageView()
    private var phase: AgentPhase?

    private var discRect: NSRect { bounds.insetBy(dx: pad, dy: pad) }

    init(diameter: CGFloat, pad: CGFloat) {
        self.diameter = diameter
        self.pad = pad
        let frame = NSRect(x: 0, y: 0, width: diameter + pad * 2, height: diameter + pad * 2)
        let disc = frame.insetBy(dx: pad, dy: pad)
        spark = ClaudeMark.layer(in: disc.insetBy(dx: diameter * 0.28, dy: diameter * 0.28), color: Theme.ink.dark)
        super.init(frame: frame)
        wantsLayer = true

        layerHost.frame = bounds
        layerHost.wantsLayer = true
        discLayer.path = CGPath(ellipseIn: disc, transform: nil)
        discLayer.fillColor = Theme.canvas.dark.withAlphaComponent(0.94).cgColor

        let ringPath = CGPath(ellipseIn: disc.insetBy(dx: 1, dy: 1), transform: nil)
        ringLayer.path = ringPath
        ringLayer.fillColor = nil
        ringLayer.lineWidth = 2

        // The arc is the same circle trimmed to about a quarter; the layer is rotated, so the arc travels round the ring.
        sweep.frame = bounds
        sweep.path = ringPath
        sweep.fillColor = nil
        sweep.lineWidth = 2
        sweep.lineCap = .round
        sweep.strokeStart = 0
        sweep.strokeEnd = 0.26
        sweep.strokeColor = Theme.accent.dark.cgColor

        check.frame = bounds
        check.path = checkPath(in: disc)
        check.fillColor = nil
        check.lineWidth = 2.8
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeColor = AgentBubble.done.cgColor

        layerHost.layer?.addSublayer(discLayer)
        layerHost.layer?.addSublayer(ringLayer)
        layerHost.layer?.addSublayer(sweep)
        layerHost.layer?.addSublayer(spark)
        layerHost.layer?.addSublayer(check)
        sweep.isHidden = true
        check.isHidden = true
        addSubview(layerHost)

        glyph.frame = disc.insetBy(dx: diameter * 0.27, dy: diameter * 0.27)
        glyph.imageScaling = .scaleProportionallyUpOrDown
        glyph.contentTintColor = Theme.ink.dark
        glyph.isHidden = true
        addSubview(glyph)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// A single check stroke, in the layer's own coordinates (y up).
    private func checkPath(in disc: NSRect) -> CGPath {
        let path = CGMutablePath()
        path.move(to: CGPoint(x: disc.minX + disc.width * 0.31, y: disc.minY + disc.height * 0.50))
        path.addLine(to: CGPoint(x: disc.minX + disc.width * 0.44, y: disc.minY + disc.height * 0.36))
        path.addLine(to: CGPoint(x: disc.minX + disc.width * 0.70, y: disc.minY + disc.height * 0.65))
        return path
    }

    func setPhase(_ newPhase: AgentPhase) {
        let color = AgentBubble.color(for: newPhase)
        let working = newPhase == .idle || newPhase == .working
        // Working: a dim track under the accent arc. Otherwise the ring is the state's colour, whole.
        ringLayer.strokeColor = (working ? color.withAlphaComponent(0.22) : color).cgColor

        guard newPhase != phase else { return }
        phase = newPhase
        for layer in [ringLayer, sweep, spark, check] { layer.removeAllAnimations() }
        self.layer?.removeAnimation(forKey: "shake")

        let done = newPhase == .done
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sweep.isHidden = !working
        spark.isHidden = !working
        check.isHidden = !done
        check.strokeEnd = 1
        CATransaction.commit()
        glyph.isHidden = newPhase != .failed

        if working {
            guard !Motion.reduceMotion else { return } // Reduce Motion: the arc sits still on the ring
            // An accent arc sweeps round the ring…
            let spin = Self.basic("transform.rotation.z", from: 0, to: -2 * Double.pi)
            spin.duration = 1.4
            spin.repeatCount = .infinity
            sweep.add(spin, forKey: "sweep")
            // …and the spark turns slowly in the middle.
            let turn = Self.basic("transform.rotation.z", from: 0, to: -2 * Double.pi)
            turn.duration = 9
            turn.repeatCount = .infinity
            spark.add(turn, forKey: "turn")
        } else if done {
            celebrate()
        } else {
            glyph.image = NSImage(systemSymbolName: "exclamationmark", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: diameter * 0.3, weight: .bold))
            Motion.popIn(glyph, from: 0.3, damping: 10, stiffness: 300)
            shake()
        }
    }

    /// The finish: the check draws on (trim 0 to 1 over 300 ms). Also replayed whenever a finished circle reappears.
    /// Under Reduce Motion the check fades in instead.
    func celebrate() {
        guard phase == .done else { return }
        check.removeAllAnimations()
        if Motion.still { return }
        if Motion.reduceMotion {
            let fade = Self.basic("opacity", from: 0, to: 1)
            fade.duration = 0.2
            check.add(fade, forKey: "draw")
            return
        }
        let draw = Self.basic("strokeEnd", from: 0, to: 1)
        draw.duration = 0.3
        draw.timingFunction = Motion.easeOut
        draw.fillMode = .backwards
        check.add(draw, forKey: "draw")
    }

    /// Red pencil: a short side-to-side shake, two cycles of 4 pt.
    private func shake() {
        guard !Motion.reduceMotion, !Motion.still, let layer = self.layer else { return }
        let a = CAKeyframeAnimation(keyPath: "transform.translation.x")
        a.values = [0, 4, -4, 4, -4, 0]
        a.keyTimes = [0, 0.2, 0.4, 0.6, 0.8, 1]
        a.duration = 0.32
        a.timingFunction = Motion.easeOut
        layer.add(a, forKey: "shake")
    }

    private static func basic(_ keyPath: String, from: Any, to: Any) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        return a
    }

    /// The circle only draws; the row it sits in takes the clicks.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
