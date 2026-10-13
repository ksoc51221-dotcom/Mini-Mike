import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Environment

private struct ActivityKey: EnvironmentKey {
    static let defaultValue: () -> Void = {}
}

extension EnvironmentValues {
    /// Called when you use something in the chat (like dragging a graph's slider), so it doesn't fade.
    var marginActivity: () -> Void {
        get { self[ActivityKey.self] }
        set { self[ActivityKey.self] = newValue }
    }
}

/// Graphs already read, so a streaming answer doesn't re-read the JSON every frame.
enum GraphCache {
    private static var cache: [String: GraphSpec?] = [:]

    static func spec(for source: String) -> GraphSpec? {
        if let hit = cache[source] { return hit }
        let spec = GraphSpec.parse(source)
        if cache.count > 40 { cache.removeAll() }
        cache[source] = .some(spec)
        return spec
    }
}

// MARK: - The graph card in a chat

/// A graph Claude drew: the drawing, its sliders, and a line on what to notice. Hover to read values;
/// drag it out (or right-click) to keep it as a picture.
struct GraphView: View {
    let source: String
    private let spec: GraphSpec?
    @State private var values: [String: Double]
    @State private var hover: CGPoint?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.marginActivity) private var activity

    init(source: String) {
        self.source = source
        let spec = GraphCache.spec(for: source)
        self.spec = spec
        _values = State(initialValue: spec?.initialValues ?? [:])
    }

    var body: some View {
        if let spec {
            card(spec)
        } else {
            Label("Couldn't draw this graph.", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func card(_ spec: GraphSpec) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if spec.title != nil || !spec.sliders.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let title = spec.title {
                        Text(title)
                            .font(.callout.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if values != spec.initialValues {
                        Button {
                            withAnimation(.snappy(duration: 0.3)) { values = spec.initialValues }
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .transition(.opacity)
                    }
                }
            }
            GraphCanvas(spec: spec, values: values, hover: hover, dark: scheme == .dark)
                .aspectRatio(1 / spec.aspect, contentMode: .fit)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p):
                        hover = p
                        activity()
                    case .ended:
                        hover = nil
                    }
                }
                .onDrag { dragItem(spec) }
                .contextMenu {
                    Button("Copy Image") { copyImage(spec) }
                    Button("Save Image As…") { saveImage(spec) }
                }
                .help("Drag it out to keep it, or right-click to copy")
            ForEach(spec.sliders) { slider in
                sliderRow(slider)
            }
            if let caption = spec.caption {
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !spec.problems.isEmpty {
                Text(spec.problems.count == 1 ? "Skipped 1 part that didn't make sense." :
                        "Skipped \(spec.problems.count) parts that didn't make sense.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help(spec.problems.joined(separator: "\n"))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
    }

    private func sliderRow(_ s: GraphSpec.Slider) -> some View {
        let binding = Binding<Double>(
            get: { values[s.name] ?? s.value },
            set: {
                values[s.name] = $0
                activity()
            })
        return HStack(spacing: 8) {
            Text(s.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Group {
                if let step = s.step {
                    Slider(value: binding, in: s.min...s.max, step: step)
                } else {
                    Slider(value: binding, in: s.min...s.max)
                }
            }
            .controlSize(.small)
            .tint(Color(nsColor: Theme.accent))
            Text(MathFormat.short(values[s.name] ?? s.value))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 34, alignment: .trailing)
        }
    }

    // MARK: Keeping it

    /// The graph as it looks now (sliders included), as a 2× picture with a solid background.
    @MainActor
    private func image(_ spec: GraphSpec) -> NSImage? {
        let width: CGFloat = 640
        let renderer = ImageRenderer(content:
            VStack(alignment: .leading, spacing: 8) {
                if let title = spec.title {
                    Text(title).font(.system(size: 15, weight: .semibold))
                }
                GraphCanvas(spec: spec, values: values, hover: nil, dark: scheme == .dark)
                    .frame(width: width, height: width * spec.aspect)
            }
            .padding(18)
            .background(scheme == .dark ? Color(white: 0.12) : Color.white)
            .environment(\.colorScheme, scheme)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor
    private func pngData(_ spec: GraphSpec) -> Data? {
        guard let tiff = image(spec)?.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }

    private func fileName(_ spec: GraphSpec) -> String {
        let base = (spec.title ?? "Graph").components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>")).joined(separator: "-")
        return String(base.prefix(60)) + ".png"
    }

    @MainActor
    private func dragItem(_ spec: GraphSpec) -> NSItemProvider {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("margin-graphs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(fileName(spec))
        guard let data = pngData(spec), (try? data.write(to: url)) != nil else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }

    @MainActor
    private func copyImage(_ spec: GraphSpec) {
        guard let image = image(spec) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    @MainActor
    private func saveImage(_ spec: GraphSpec) {
        guard let data = pngData(spec) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = fileName(spec)
        panel.allowedContentTypes = [.png]
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let dest = panel.url else { return }
        try? data.write(to: dest)
    }
}

/// Just the drawing (also used for pictures and demos).
struct GraphCanvas: View {
    let spec: GraphSpec
    let values: [String: Double]
    let hover: CGPoint?
    let dark: Bool

    var body: some View {
        Canvas { context, size in
            GraphRenderer(spec: spec, values: values, hover: hover, dark: dark).draw(&context, size: size)
        }
    }
}

// MARK: - Drawing

struct GraphRenderer {
    let spec: GraphSpec
    let values: [String: Double]
    let hover: CGPoint?
    let dark: Bool

    private var ink: Color { dark ? Color(white: 0.92) : Color(white: 0.12) }
    private var halo: Color { dark ? Color(white: 0.15) : Color(white: 0.985) }

    private func color(_ c: GraphColor?) -> Color {
        guard let c else { return ink }
        return Color(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }

    private func text(_ s: String, size: CGFloat = 10.5, weight: Font.Weight = .medium, color: Color? = nil) -> Text {
        Text(s).font(.system(size: size, weight: weight)).foregroundStyle(color ?? ink.opacity(0.78))
    }

    /// Where things go on screen.
    private struct Layout {
        let plot: CGRect
        let x: ClosedRange<Double>
        let y: ClosedRange<Double>
        /// Where the axes cross, in graph units (0 when it's in view, else the bottom/left edge).
        let xAxisAt: Double
        let yAxisAt: Double

        func sx(_ v: Double) -> CGFloat { plot.minX + CGFloat((v - x.lowerBound) / x.span) * plot.width }
        func sy(_ v: Double) -> CGFloat { plot.maxY - CGFloat((v - y.lowerBound) / y.span) * plot.height }
        func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: sx(Double(p.x)), y: sy(Double(p.y))) }
        func dataX(_ s: CGFloat) -> Double { x.lowerBound + Double((s - plot.minX) / plot.width) * x.span }
        var xAxisAtEdge: Bool { xAxisAt == y.lowerBound }
        var yAxisAtEdge: Bool { yAxisAt == x.lowerBound }
    }

    func draw(_ ctx: inout GraphicsContext, size: CGSize) {
        guard size.width > 60, size.height > 40 else { return }
        var scene = GraphScene.build(spec, values: values, plotSize: CGSize(width: size.width - 36, height: size.height - 28))
        var layout = makeLayout(scene, size: size, ctx: ctx)
        if spec.equal { // ranges depend on the plot's real shape
            scene = GraphScene.build(spec, values: values, plotSize: layout.plot.size)
            layout = makeLayout(scene, size: size, ctx: ctx)
        }
        let L = layout
        var occupied: [CGRect] = []
        let bounds = CGRect(origin: .zero, size: size)
        var plotCtx = ctx
        plotCtx.clip(to: Path(L.plot.insetBy(dx: -1, dy: -1)))

        let xTicks = spec.axes && spec.x.numbers ? Self.ticks(L.x, pixels: L.plot.width, piStyle: true) : []
        let yTicks = spec.axes && spec.y.numbers ? Self.ticks(L.y, pixels: L.plot.height * 1.45, piStyle: false) : []

        // Grid.
        for (v, _) in xTicks {
            let sx = L.sx(v)
            plotCtx.stroke(Path { $0.move(to: CGPoint(x: sx, y: L.plot.minY)); $0.addLine(to: CGPoint(x: sx, y: L.plot.maxY)) },
                           with: .color(ink.opacity(0.07)), lineWidth: 0.6)
        }
        for (v, _) in yTicks {
            let sy = L.sy(v)
            plotCtx.stroke(Path { $0.move(to: CGPoint(x: L.plot.minX, y: sy)); $0.addLine(to: CGPoint(x: L.plot.maxX, y: sy)) },
                           with: .color(ink.opacity(0.07)), lineWidth: 0.6)
        }

        // Shaded areas.
        for region in scene.regions {
            var path = Path()
            path.addLines(region.polygon.map(L.pt))
            path.closeSubpath()
            plotCtx.fill(path, with: .color(color(region.color).opacity(0.22)))
        }

        // Axes, ticks and numbers.
        if spec.axes {
            drawAxes(&ctx, L, xTicks: xTicks, yTicks: yTicks, occupied: &occupied)
        }

        // Reference lines (axis of symmetry, price ceiling, tangent).
        for s in scene.strokes where s.infinite {
            let path = Path { $0.move(to: L.pt(s.from)); $0.addLine(to: L.pt(s.to)) }
            plotCtx.stroke(path, with: .color(s.color.map(color) ?? ink.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 1.3, lineCap: .round, dash: s.dashed ? [5, 4] : []))
        }

        // Curves.
        for curve in scene.curves {
            for seg in curve.segments {
                var path = Path()
                path.addLines(seg.map(L.pt))
                plotCtx.stroke(path, with: .color(color(curve.color)),
                               style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round, dash: curve.dashed ? [7, 5] : []))
            }
        }

        // Shapes (diagrams, vectors, geometry).
        for figure in scene.figures {
            drawFigure(&ctx, figure, L, occupied: &occupied)
        }
        for s in scene.strokes where !s.infinite {
            let a = L.pt(s.from), b = L.pt(s.to)
            let c = s.color.map(color) ?? ink.opacity(0.8)
            ctx.stroke(Path { $0.move(to: a); $0.addLine(to: b) }, with: .color(c),
                       style: StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: s.dashed ? [5, 4] : []))
            if s.arrow { ctx.fill(arrowhead(at: b, from: a, size: 9), with: .color(c)) }
        }

        // Labels steer clear of the curves and reference lines (when there's room elsewhere).
        for curve in scene.curves {
            for seg in curve.segments {
                for p in seg.map(L.pt) where L.plot.contains(p) {
                    occupied.append(CGRect(x: p.x - 2, y: p.y - 2, width: 4, height: 4))
                }
            }
        }
        for s in scene.strokes where s.infinite {
            guard let (a, b) = clipSegment(L.pt(s.from), L.pt(s.to), to: L.plot) else { continue }
            for k in 0...40 {
                let t = CGFloat(k) / 40
                occupied.append(CGRect(x: a.x + (b.x - a.x) * t - 2, y: a.y + (b.y - a.y) * t - 2, width: 4, height: 4))
            }
        }

        // Dashed guides from points down to the axes (Q*, P*).
        for dot in scene.dots {
            guard let guides = dot.guides, L.plot.insetBy(dx: -1, dy: -1).contains(L.pt(dot.at)) else { continue }
            let p = L.pt(dot.at)
            let foot = CGPoint(x: p.x, y: L.sy(L.xAxisAt)), side = CGPoint(x: L.sx(L.yAxisAt), y: p.y)
            let style = StrokeStyle(lineWidth: 1, dash: [3, 3])
            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: foot) }, with: .color(ink.opacity(0.45)), style: style)
            ctx.stroke(Path { $0.move(to: p); $0.addLine(to: side) }, with: .color(ink.opacity(0.45)), style: style)
            let xName = guides.xLabel ?? (spec.x.numbers ? MathFormat.short(Double(dot.at.x)) : nil)
            let yName = guides.yLabel ?? (spec.y.numbers ? MathFormat.short(Double(dot.at.y)) : nil)
            if let xName {
                place(&ctx, text(xName, size: 10, weight: .semibold), [(CGPoint(x: foot.x, y: foot.y + 3), .top)],
                      occupied: &occupied, bounds: bounds, force: true)
            }
            if let yName {
                place(&ctx, text(yName, size: 10, weight: .semibold), [(CGPoint(x: side.x - 4, y: side.y), .trailing)],
                      occupied: &occupied, bounds: bounds, force: true)
            }
        }

        // Points.
        for dot in scene.dots {
            let p = L.pt(dot.at)
            guard L.plot.insetBy(dx: -2, dy: -2).contains(p) else { continue }
            let r: CGFloat = 4
            let circle = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            let c = dot.color.map(color) ?? ink
            if dot.hollow {
                ctx.fill(circle, with: .color(halo))
                ctx.stroke(circle, with: .color(c), lineWidth: 1.6)
            } else {
                ctx.fill(circle, with: .color(c))
                ctx.stroke(circle, with: .color(halo.opacity(0.9)), lineWidth: 1.2)
            }
            occupied.append(CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
        }

        // Labels: points first (they matter most), then curves, lines and areas.
        for dot in scene.dots {
            guard let label = dot.label else { continue }
            let p = L.pt(dot.at)
            guard L.plot.insetBy(dx: -2, dy: -2).contains(p) else { continue }
            place(&ctx, text(label, size: 11, weight: .semibold, color: dot.color.map(color) ?? ink),
                  [(CGPoint(x: p.x + 6, y: p.y - 5), .bottomLeading), (CGPoint(x: p.x - 6, y: p.y - 5), .bottomTrailing),
                   (CGPoint(x: p.x + 6, y: p.y + 5), .topLeading), (CGPoint(x: p.x - 6, y: p.y + 5), .topTrailing)],
                  occupied: &occupied, bounds: L.plot, force: true)
        }
        for curve in scene.curves {
            guard let label = curve.label else { continue }
            let visible = curve.segments.flatMap { $0 }.map(L.pt).filter { L.plot.insetBy(dx: 2, dy: 2).contains($0) }
            guard visible.count >= 2 else { continue }
            let t = text(label, size: 11, weight: .semibold, color: color(curve.color))
            let size = ctx.resolve(t).measure(in: CGSize(width: 260, height: 60))
            let clearance = 5 + max(size.width, size.height) / 2
            // At each end (and the middle): just past the end along the curve, then off either side of it.
            var spots: [(CGPoint, UnitPoint)] = []
            for (i, step) in [(visible.count - 1, -6), (0, 6), (visible.count / 2, 6)] {
                let p = visible[i], q = visible[max(0, min(visible.count - 1, i + step))]
                var d = CGPoint(x: p.x - q.x, y: p.y - q.y)
                let len = hypot(d.x, d.y)
                guard len > 0.01 else { continue }
                d = CGPoint(x: d.x / len, y: d.y / len)
                var n = CGPoint(x: -d.y, y: d.x)
                if n.y > 0 { n = CGPoint(x: -n.x, y: -n.y) } // try above the line first
                if i != visible.count / 2 { spots.append((CGPoint(x: p.x + d.x * clearance, y: p.y + d.y * clearance), .center)) }
                spots.append((CGPoint(x: p.x + n.x * clearance, y: p.y + n.y * clearance), .center))
                spots.append((CGPoint(x: p.x - n.x * clearance, y: p.y - n.y * clearance), .center))
            }
            place(&ctx, t, spots, occupied: &occupied, bounds: L.plot, force: true)
        }
        for s in scene.strokes {
            guard let label = s.label else { continue }
            let a = L.pt(s.from), b = L.pt(s.to)
            let c = s.color.map(color) ?? ink.opacity(0.7)
            if s.infinite {
                guard let (enter, exit) = clipSegment(a, b, to: L.plot) else { continue }
                let t = text(label, size: 10, color: c)
                var spots: [(CGPoint, UnitPoint)]
                if abs(exit.x - enter.x) < 0.5 { // vertical: at the top, beside the line
                    let top = enter.y < exit.y ? enter : exit
                    spots = [(CGPoint(x: top.x + 4, y: top.y + 3), .topLeading), (CGPoint(x: top.x - 4, y: top.y + 3), .topTrailing)]
                } else { // just inside where it leaves the graph (right end first), off to one side
                    let size = ctx.resolve(t).measure(in: CGSize(width: 260, height: 60))
                    let clearance = 5 + max(size.width, size.height) / 2
                    spots = []
                    for (p, q) in [enter.x > exit.x ? (enter, exit) : (exit, enter), enter.x > exit.x ? (exit, enter) : (enter, exit)] {
                        let len = max(hypot(p.x - q.x, p.y - q.y), 0.01)
                        let d = CGPoint(x: (p.x - q.x) / len, y: (p.y - q.y) / len)
                        var n = CGPoint(x: -d.y, y: d.x)
                        if n.y > 0 { n = CGPoint(x: -n.x, y: -n.y) }
                        let back = CGPoint(x: p.x - d.x * clearance * 1.6, y: p.y - d.y * clearance * 1.6)
                        spots.append((CGPoint(x: back.x + n.x * clearance, y: back.y + n.y * clearance), .center))
                        spots.append((CGPoint(x: back.x - n.x * clearance, y: back.y - n.y * clearance), .center))
                    }
                }
                place(&ctx, t, spots, occupied: &occupied, bounds: L.plot, force: true)
            } else {
                let m = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                let len = max(hypot(b.x - a.x, b.y - a.y), 1)
                let n = CGPoint(x: -(b.y - a.y) / len, y: (b.x - a.x) / len) // perpendicular
                place(&ctx, text(label, size: 10.5, weight: .semibold, color: c),
                      [(CGPoint(x: m.x + n.x * 8, y: m.y + n.y * 8), .center), (CGPoint(x: m.x - n.x * 8, y: m.y - n.y * 8), .center)],
                      occupied: &occupied, bounds: bounds, force: true)
            }
        }
        for region in scene.regions {
            guard let label = region.label else { continue }
            let p = L.pt(region.labelAt)
            guard L.plot.contains(p) else { continue }
            place(&ctx, text(label, size: 10, weight: .semibold, color: ink.opacity(0.85)), [(p, .center)],
                  occupied: &occupied, bounds: L.plot, force: true, haloOpacity: 0.55)
        }

        // Hover: read the curves' values at the mouse.
        if let hover, L.plot.contains(hover), spec.axes, spec.x.numbers, !scene.readings.isEmpty {
            drawReadout(&ctx, L, scene: scene, at: hover)
        }
    }

    // MARK: Layout

    private func makeLayout(_ scene: GraphScene, size: CGSize, ctx: GraphicsContext) -> Layout {
        let x = scene.xRange, y = scene.yRange
        let xAxisAt = y.contains(0) && y.lowerBound < 0 ? 0 : y.lowerBound
        let yAxisAt = x.contains(0) && x.lowerBound < 0 ? 0 : x.lowerBound
        let xAtEdge = xAxisAt == y.lowerBound, yAtEdge = yAxisAt == x.lowerBound
        let guideX = scene.dots.contains { $0.guides != nil }
        var left: CGFloat = 10, bottom: CGFloat = 8, top: CGFloat = 8
        if spec.axes {
            if yAtEdge {
                var widest: CGFloat = 0
                if spec.y.numbers {
                    for (_, s) in Self.ticks(y, pixels: size.height * 1.2, piStyle: false) {
                        widest = max(widest, ctx.resolve(text(s, size: 9.5)).measure(in: size).width)
                    }
                }
                for dot in scene.dots {
                    guard let g = dot.guides else { continue }
                    let s = g.yLabel ?? (spec.y.numbers ? MathFormat.short(Double(dot.at.y)) : "")
                    widest = max(widest, ctx.resolve(text(s, size: 10, weight: .semibold)).measure(in: size).width)
                }
                if widest > 0 { left = widest + 9 }
            }
            if xAtEdge && (spec.x.numbers || spec.x.label != nil || guideX) { bottom = 20 }
            if spec.y.label != nil { top = 20 }
        }
        let plot = CGRect(x: left, y: top, width: max(10, size.width - left - 12), height: max(10, size.height - top - bottom))
        return Layout(plot: plot, x: x, y: y, xAxisAt: xAxisAt, yAxisAt: yAxisAt)
    }

    // MARK: Axes

    private func drawAxes(_ ctx: inout GraphicsContext, _ L: Layout, xTicks: [(Double, String)], yTicks: [(Double, String)],
                          occupied: inout [CGRect]) {
        let axisColor = ink.opacity(0.55)
        let ax = L.sy(L.xAxisAt), ay = L.sx(L.yAxisAt)
        let xStart = CGPoint(x: L.plot.minX, y: ax), xEnd = CGPoint(x: L.plot.maxX + 6, y: ax)
        let yStart = CGPoint(x: ay, y: L.plot.maxY), yEnd = CGPoint(x: ay, y: L.plot.minY - 6)
        ctx.stroke(Path { $0.move(to: xStart); $0.addLine(to: xEnd) }, with: .color(axisColor), lineWidth: 1.1)
        ctx.stroke(Path { $0.move(to: yStart); $0.addLine(to: yEnd) }, with: .color(axisColor), lineWidth: 1.1)
        ctx.fill(arrowhead(at: xEnd, from: xStart, size: 6), with: .color(axisColor))
        ctx.fill(arrowhead(at: yEnd, from: yStart, size: 6), with: .color(axisColor))

        // Axis names: x at the right end (below the axis on the edge, above it in the middle), y at the top.
        if let name = spec.x.label {
            let t = text(name, size: 10.5, weight: .semibold, color: ink.opacity(0.7))
            let spot: (CGPoint, UnitPoint) = L.xAxisAtEdge ? (CGPoint(x: L.plot.maxX, y: ax + 4), .topTrailing)
                                                           : (CGPoint(x: L.plot.maxX, y: ax - 4), .bottomTrailing)
            place(&ctx, t, [spot], occupied: &occupied, bounds: CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)),
                  force: true, haloOpacity: 0)
        }
        if let name = spec.y.label {
            let t = text(name, size: 10.5, weight: .semibold, color: ink.opacity(0.7))
            place(&ctx, t, [(CGPoint(x: ay + 2, y: L.plot.minY - 7), .bottomLeading)], occupied: &occupied,
                  bounds: CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)), force: true, haloOpacity: 0)
        }

        let bothInside = !L.xAxisAtEdge && !L.yAxisAtEdge
        for (v, s) in xTicks {
            let sx = L.sx(v)
            guard sx > L.plot.minX + 4, sx < L.plot.maxX - 4 else { continue }
            if bothInside && abs(v) < 1e-12 { continue } // one "0" at the origin instead
            ctx.stroke(Path { $0.move(to: CGPoint(x: sx, y: ax - 2.5)); $0.addLine(to: CGPoint(x: sx, y: ax + 2.5)) },
                       with: .color(axisColor), lineWidth: 1)
            place(&ctx, text(s, size: 9.5, weight: .regular, color: ink.opacity(0.55)), [(CGPoint(x: sx, y: ax + 4), .top)],
                  occupied: &occupied, bounds: CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)), haloOpacity: 0.6)
        }
        for (v, s) in yTicks {
            let sy = L.sy(v)
            guard sy > L.plot.minY + 4, sy < L.plot.maxY - 4 else { continue }
            if bothInside && abs(v) < 1e-12 { continue }
            ctx.stroke(Path { $0.move(to: CGPoint(x: ay - 2.5, y: sy)); $0.addLine(to: CGPoint(x: ay + 2.5, y: sy)) },
                       with: .color(axisColor), lineWidth: 1)
            place(&ctx, text(s, size: 9.5, weight: .regular, color: ink.opacity(0.55)), [(CGPoint(x: ay - 4, y: sy), .trailing)],
                  occupied: &occupied, bounds: CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)), haloOpacity: 0.6)
        }
        if bothInside && (spec.x.numbers || spec.y.numbers) {
            place(&ctx, text("0", size: 9.5, weight: .regular, color: ink.opacity(0.55)), [(CGPoint(x: ay - 3, y: ax + 3), .topTrailing)],
                  occupied: &occupied, bounds: CGRect(origin: .zero, size: CGSize(width: 1e5, height: 1e5)), haloOpacity: 0.6)
        }
    }

    /// Nice tick positions (1, 2, 5 × 10ⁿ), or multiples of π/2 when the range is in π.
    static func ticks(_ r: ClosedRange<Double>, pixels: CGFloat, piStyle: Bool) -> [(Double, String)] {
        let span = r.span
        guard span > 0, span.isFinite, pixels > 20 else { return [] }
        let quarter = Double.pi / 2
        func isPiMultiple(_ v: Double) -> Bool { abs(v / quarter - (v / quarter).rounded()) < 1e-3 }
        if piStyle, isPiMultiple(r.lowerBound), isPiMultiple(r.upperBound), span >= quarter * 0.99,
           r.lowerBound != 0 || r.upperBound.truncatingRemainder(dividingBy: 1) != 0 {
            let halves = span / quarter
            let step = halves <= 9 ? 1 : halves <= 18 ? 2 : 4 // in units of π/2
            let first = Int((r.lowerBound / quarter).rounded(.up)), last = Int((r.upperBound / quarter).rounded(.down))
            return stride(from: first - (first % step + step) % step, through: last, by: step)
                .filter { $0 >= first }
                .map { k in (Double(k) * quarter, Self.piLabel(k)) }
        }
        let target = max(2, Double(pixels / 58))
        let raw = span / target
        let magnitude = pow(10, floor(log10(raw)))
        let n = raw / magnitude
        let step = (n < 1.5 ? 1 : n < 3.5 ? 2 : n < 7.5 ? 5 : 10) * magnitude
        var out: [(Double, String)] = []
        var v = (r.lowerBound / step).rounded(.up) * step
        while v <= r.upperBound + step * 1e-9, out.count < 40 {
            let clean = abs(v) < step * 1e-9 ? 0 : v
            out.append((clean, MathFormat.short(clean)))
            v += step
        }
        return out
    }

    /// k·π/2 as a label: π/2, π, 3π/2, 2π, −π/2.
    static func piLabel(_ k: Int) -> String {
        if k == 0 { return "0" }
        let sign = k < 0 ? "−" : ""
        let a = abs(k)
        if a % 2 == 0 {
            let m = a / 2
            return sign + (m == 1 ? "π" : "\(m)π")
        }
        return sign + (a == 1 ? "π/2" : "\(a)π/2")
    }

    // MARK: Shapes

    private func drawFigure(_ ctx: inout GraphicsContext, _ figure: GraphScene.Figure, _ L: Layout, occupied: inout [CGRect]) {
        let bounds = CGRect(x: 0, y: 0, width: L.plot.maxX + 12, height: L.plot.maxY + 20)
        switch figure {
        case .polygon(let pts, let label, let c, let dashed, let filled):
            var path = Path()
            path.addLines(pts.map(L.pt))
            path.closeSubpath()
            let stroke = c.map(color) ?? ink.opacity(0.75)
            ctx.fill(path, with: .color(stroke.opacity(filled ? 0.28 : 0.1)))
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.6, lineJoin: .round, dash: dashed ? [5, 4] : []))
            if let label {
                place(&ctx, text(label, size: 10.5, weight: .semibold), [(L.pt(GraphScene.centroid(pts)), .center)],
                      occupied: &occupied, bounds: bounds, force: true, haloOpacity: 0.5)
            }
        case .circle(let center, let radius, let label, let c, let dashed, let filled):
            let p = L.pt(center)
            let rx = abs(L.sx(Double(center.x) + radius) - p.x), ry = abs(L.sy(Double(center.y) + radius) - p.y)
            let path = Path(ellipseIn: CGRect(x: p.x - rx, y: p.y - ry, width: 2 * rx, height: 2 * ry))
            let stroke = c.map(color) ?? ink.opacity(0.75)
            if filled { ctx.fill(path, with: .color(stroke.opacity(0.2))) }
            ctx.stroke(path, with: .color(stroke), style: StrokeStyle(lineWidth: 1.6, dash: dashed ? [5, 4] : []))
            if let label {
                place(&ctx, text(label, size: 10.5, weight: .semibold, color: stroke),
                      [(CGPoint(x: p.x, y: p.y - ry - 4), .bottom), (CGPoint(x: p.x + rx + 4, y: p.y), .leading)],
                      occupied: &occupied, bounds: bounds, force: true)
            }
        case .box(let rect, let label, let c, let dashed):
            let a = L.pt(CGPoint(x: rect.minX, y: rect.maxY)), b = L.pt(CGPoint(x: rect.maxX, y: rect.minY))
            let r = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
            let shape = Path(roundedRect: r, cornerRadius: min(8, r.height / 3))
            let tint = c.map(color) ?? Color(nsColor: Theme.accent)
            ctx.fill(shape, with: .color(tint.opacity(0.16)))
            ctx.stroke(shape, with: .color(tint.opacity(0.9)), style: StrokeStyle(lineWidth: 1.4, dash: dashed ? [5, 4] : []))
            if let label {
                let t = ctx.resolve(text(label, size: 10.5, weight: .semibold, color: ink.opacity(0.9)))
                let inner = r.insetBy(dx: 5, dy: 3)
                let needed = t.measure(in: inner.size)
                ctx.draw(t, in: CGRect(x: inner.midX - needed.width / 2, y: inner.midY - needed.height / 2,
                                       width: needed.width, height: needed.height))
            }
            occupied.append(r)
        case .text(let s, let at, let c):
            place(&ctx, text(s, size: 10.5, weight: .medium, color: c.map(color) ?? ink.opacity(0.85)), [(L.pt(at), .center)],
                  occupied: &occupied, bounds: bounds, force: true, haloOpacity: 0)
        }
    }

    private func arrowhead(at tip: CGPoint, from tail: CGPoint, size: CGFloat) -> Path {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let spread: CGFloat = 0.45
        return Path { p in
            p.move(to: tip)
            p.addLine(to: CGPoint(x: tip.x - size * cos(angle - spread), y: tip.y - size * sin(angle - spread)))
            p.addLine(to: CGPoint(x: tip.x - size * cos(angle + spread), y: tip.y - size * sin(angle + spread)))
            p.closeSubpath()
        }
    }

    /// The part of the line a→b inside `rect` (Liang–Barsky), or nil if it misses.
    private func clipSegment(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        var t0: CGFloat = 0, t1: CGFloat = 1
        let dx = b.x - a.x, dy = b.y - a.y
        for (p, q) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return nil }
                continue
            }
            let r = q / p
            if p < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            if t0 > t1 { return nil }
        }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }

    // MARK: Labels

    /// Draws `t` at the first spot where it fits inside `bounds` without covering another label;
    /// with `force`, uses the first spot when none fits. A soft background keeps it readable over lines.
    private func place(_ ctx: inout GraphicsContext, _ t: Text, _ spots: [(CGPoint, UnitPoint)], occupied: inout [CGRect],
                       bounds: CGRect, force: Bool = false, haloOpacity: Double = 0.8) {
        let resolved = ctx.resolve(t)
        let size = resolved.measure(in: CGSize(width: 260, height: 60))
        func rect(_ spot: (CGPoint, UnitPoint)) -> CGRect {
            CGRect(x: spot.0.x - spot.1.x * size.width, y: spot.0.y - spot.1.y * size.height, width: size.width, height: size.height)
        }
        let fits = spots.first { spot in
            let r = rect(spot)
            return bounds.contains(r) && !occupied.contains { $0.intersects(r.insetBy(dx: -2, dy: -1)) }
        }
        guard let spot = fits ?? (force ? spots.first : nil) else { return }
        let r = rect(spot)
        if haloOpacity > 0 {
            ctx.fill(Path(roundedRect: r.insetBy(dx: -3, dy: -1), cornerRadius: 3), with: .color(halo.opacity(haloOpacity)))
        }
        ctx.draw(resolved, at: spot.0, anchor: spot.1)
        occupied.append(r)
    }

    // MARK: Hover

    private func drawReadout(_ ctx: inout GraphicsContext, _ L: Layout, scene: GraphScene, at hover: CGPoint) {
        let x = L.dataX(hover.x)
        ctx.stroke(Path { $0.move(to: CGPoint(x: hover.x, y: L.plot.minY)); $0.addLine(to: CGPoint(x: hover.x, y: L.plot.maxY)) },
                   with: .color(ink.opacity(0.22)), lineWidth: 1)
        var lines = ["x = \(MathFormat.short(x))"]
        for reading in scene.readings.prefix(4) {
            let y = reading.value(x)
            guard y.isFinite else { continue }
            lines.append("\(reading.label) = \(MathFormat.short(y))")
            guard L.y.contains(y) else { continue }
            let p = CGPoint(x: hover.x, y: L.sy(y)), r: CGFloat = 3.5
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)), with: .color(color(reading.color)))
        }
        let t = ctx.resolve(text(lines.joined(separator: "\n"), size: 10, weight: .medium, color: ink.opacity(0.9)))
        let size = t.measure(in: CGSize(width: 220, height: 120))
        var origin = CGPoint(x: hover.x + 10, y: L.plot.minY + 6)
        if origin.x + size.width + 8 > L.plot.maxX { origin.x = hover.x - 10 - size.width - 8 }
        let box = CGRect(x: origin.x, y: origin.y, width: size.width + 8, height: size.height + 6)
        ctx.fill(Path(roundedRect: box, cornerRadius: 5), with: .color(halo.opacity(0.92)))
        ctx.stroke(Path(roundedRect: box, cornerRadius: 5), with: .color(ink.opacity(0.12)), lineWidth: 1)
        ctx.draw(t, at: CGPoint(x: box.minX + 4, y: box.minY + 3), anchor: .topLeading)
    }
}
