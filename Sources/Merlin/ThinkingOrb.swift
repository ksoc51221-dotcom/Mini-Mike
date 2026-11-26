import AppKit
import SwiftUI

// The SwiftUI side of the thinking orbs (engine and MIT notice: OrbEngine.swift).

/// A dotted 3D orb that shows what Claude is doing: one shape per state (orbits while working, a scanning globe while
/// searching, a slow ring for Local mode…). Grey ink, mirrored on dark surfaces. One still frame with Reduce Motion,
/// and it stops drawing while its window is hidden.
struct ThinkingOrb: View {
    var state: Orb.State = .working
    var size: CGFloat = 20
    /// Force the ink for a surface that is always dark (or light). nil follows the window's appearance.
    var dark: Bool? = nil
    var speed: Double = 1

    @Environment(\.colorScheme) private var scheme
    @State private var shown = true

    /// One clock for every orb, so two orbs on screen stay in step.
    static let epoch = Date()
    /// The spec's still frame for Reduce Motion.
    static let stillTime = 0.6

    private var still: Bool { Motion.still || Motion.reduceMotion }
    /// Off for headless pictures: `ImageRenderer` can't draw the AppKit probe.
    nonisolated(unsafe) static var watchWindow = true

    /// `--orbshots <dir>`: every state, light and dark, plus the Thinking line, as PNGs (no window).
    @MainActor static func renderShots(to dir: URL) {
        watchWindow = false
        Motion.still = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let sheet = VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 18) {
                    ForEach(Orb.State.allCases, id: \.self) { s in
                        VStack(spacing: 6) {
                            ThinkingOrb(state: s, size: 64, dark: dark)
                            Text(s.rawValue).font(.system(size: 10)).foregroundStyle(dark ? .white : .black)
                        }
                    }
                }
                HStack(spacing: 18) {
                    ForEach(Orb.State.allCases, id: \.self) { s in ThinkingOrb(state: s, size: 18, dark: dark).frame(width: 64) }
                }
                ThinkingIndicator(status: "Searching “swift 6.4 release”").environment(\.colorScheme, dark ? .dark : .light)
                ThinkingIndicator().environment(\.colorScheme, dark ? .dark : .light)
            }
            .padding(20)
            .background(Color(nsColor: Theme.canvas.resolved(dark: dark)))
            let r = ImageRenderer(content: sheet)
            r.scale = 2
            if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: dir.appendingPathComponent(dark ? "orbs-dark.png" : "orbs-light.png"))
            }
        }
        print("orb shots in \(dir.path)")
        exit(0)
    }

    var body: some View {
        let preset: Orb.Size = size > 40 ? .large : .small
        let resolved = Orb.resolve(state, preset)
        let isDark = dark ?? (scheme == .dark)
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still || !shown)) { context in
            let t = still ? Self.stillTime : context.date.timeIntervalSince(Self.epoch) * resolved.speed * speed
            Canvas { ctx, canvasSize in
                let base = Double(preset.rawValue)
                let k = min(canvasSize.width, canvasSize.height) / base
                ctx.translateBy(x: (canvasSize.width - base * k) / 2, y: (canvasSize.height - base * k) / 2)
                ctx.scaleBy(x: k, y: k)
                Self.draw(Orb.frame(resolved.mode, size: base, t: t, opts: resolved.opts), in: &ctx, dark: isDark)
            }
        }
        .frame(width: size, height: size)
        .background { if Self.watchWindow { WindowShownProbe { shown = $0 } } }
        .accessibilityElement()
        .accessibilityLabel(state.label)
        .accessibilityAddTraits(.isImage)
    }

    private static func ink(_ white: Double, _ alpha: Double, dark: Bool) -> Color {
        let w = min(1, max(0, white))
        let g = (dark ? 1 - w : w)
        return Color(.sRGB, white: (g * 255).rounded() / 255, opacity: alpha)
    }

    /// Lines first, then the dots in the order the engine gives (already far to near).
    static func draw(_ frame: Orb.Frame, in ctx: inout GraphicsContext, dark: Bool) {
        for l in frame.lines {
            var p = Path()
            p.move(to: CGPoint(x: l.x1, y: l.y1))
            p.addLine(to: CGPoint(x: l.x2, y: l.y2))
            ctx.stroke(p, with: .color(ink(l.white, l.a, dark: dark)), lineWidth: l.w)
        }
        for d in frame.dots {
            ctx.fill(Path(ellipseIn: CGRect(x: d.x - d.r, y: d.y - d.r, width: d.r * 2, height: d.r * 2)),
                     with: .color(ink(d.white, d.a, dark: dark)))
        }
    }

    /// Which orb fits a status line. Plain thinking is `working`; Local mode gets the calm ring.
    static func state(forStatus status: String?, local: Bool = false) -> Orb.State {
        guard let s = status, !s.isEmpty else { return local ? .breathing : .working }
        if s.hasPrefix("Searching") { return .searching }
        if s.hasPrefix("Reading part") || s.hasPrefix("Writing") { return .composing }
        if s.hasPrefix("Reading") { return .connecting }
        if s.hasPrefix("Listening") { return .listening }
        return local ? .breathing : .working
    }
}

/// Tells its owner when the window it sits in is hidden (minimised, closed, fully covered) or shown again.
private struct WindowShownProbe: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> ProbeView { ProbeView(onChange: onChange) }
    func updateNSView(_ view: ProbeView, context: Context) { view.onChange = onChange }

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void
        private var observers: [NSObjectProtocol] = []
        private var last: Bool?

        init(onChange: @escaping (Bool) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { report(false); return }
            let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                              NSWindow.didDeminiaturizeNotification]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check() }
                }
            }
            check()
        }

        private func check() {
            guard let window else { return report(false) }
            report(window.occlusionState.contains(.visible) && !window.isMiniaturized)
        }

        private func report(_ shown: Bool) {
            guard shown != last else { return }
            last = shown
            let callback = onChange
            DispatchQueue.main.async { callback(shown) }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }
}
