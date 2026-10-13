import CoreGraphics
import Foundation

/// A graph or visual model Claude drew, read from the JSON inside a <graph> tag (the format is taught
/// in `Prompts.system`). Everything numeric is an expression, so a graph can have sliders ("a", "shift")
/// and computed parts (point E where D meets S, the area between D and E's price).
struct GraphSpec {
    struct Axis {
        var label: String?
        var min: MathExpr?
        var max: MathExpr?
        var numbers = true
    }

    struct Slider: Identifiable {
        let name: String
        let label: String
        let min: Double
        let max: Double
        let value: Double
        let step: Double?
        var id: String { name }
    }

    /// A position: [x, y] (expressions) or a named point ("E").
    enum Coord {
        case pair(MathExpr, MathExpr)
        case point(String)
    }

    /// A curve's edge for intersections and areas: a plot by name, or an expression in x ("0", "E.y").
    enum Edge {
        case plot(String)
        case expr(MathExpr)
    }

    enum PlotKind {
        case function(MathExpr)
        case path([Coord], smooth: Bool)
        case parametric(x: MathExpr, y: MathExpr, from: MathExpr, to: MathExpr)
    }

    struct Plot {
        let name: String?
        let label: String?
        let kind: PlotKind
        let color: GraphColor
        let dashed: Bool
        let from: MathExpr?
        let to: MathExpr?
    }

    enum PointKind {
        case at(MathExpr, MathExpr)
        case intersect(Edge, Edge, near: MathExpr?, all: Bool)
        case on(String, MathExpr)
    }

    struct Guides {
        let xLabel: String?
        let yLabel: String?
    }

    struct Point {
        let name: String?
        let label: String?
        let kind: PointKind
        let guides: Guides?
        let hollow: Bool
        let color: GraphColor?
    }

    enum LineKind {
        case vertical(MathExpr)
        case horizontal(MathExpr)
        case tangent(String, at: MathExpr)
        case through(Coord, Coord)
        case slope(MathExpr, through: Coord)
    }

    struct Line {
        let kind: LineKind
        let label: String?
        let dashed: Bool
        let color: GraphColor?
    }

    struct Area {
        let top: Edge
        let bottom: Edge
        let from: MathExpr?
        let to: MathExpr?
        let label: String?
        let color: GraphColor
    }

    enum ShapeKind {
        case segment(Coord, Coord)
        case arrow(Coord, Coord)
        case polygon([Coord])
        case circle(Coord, radius: MathExpr)
        case box(Coord, width: MathExpr, height: MathExpr)
        case text(String, Coord)
    }

    struct Shape {
        let kind: ShapeKind
        let label: String?
        let color: GraphColor?
        let dashed: Bool
        let filled: Bool
    }

    var title: String?
    var caption: String?
    var x = Axis()
    var y = Axis()
    /// Same scale on both axes (circles stay round): geometry, vectors, the unit circle.
    var equal = false
    /// False hides the axes entirely, for diagrams.
    var axes = true
    /// Height ÷ width of the drawing.
    var aspect: CGFloat = 0.62
    var sliders: [Slider] = []
    var plots: [Plot] = []
    var points: [Point] = []
    var lines: [Line] = []
    var areas: [Area] = []
    var shapes: [Shape] = []
    /// Parts that couldn't be read and were skipped (shown as a quiet note).
    var problems: [String] = []

    var initialValues: [String: Double] {
        Dictionary(sliders.map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
    }
}

// MARK: - Colors

struct GraphColor: Equatable {
    let r: Double, g: Double, b: Double

    static let blue = GraphColor(r: 0.30, g: 0.57, b: 0.96)
    static let orange = GraphColor(r: 0.94, g: 0.53, b: 0.30)
    static let green = GraphColor(r: 0.26, g: 0.70, b: 0.43)
    static let red = GraphColor(r: 0.91, g: 0.33, b: 0.32)
    static let purple = GraphColor(r: 0.62, g: 0.46, b: 0.95)
    static let pink = GraphColor(r: 0.92, g: 0.42, b: 0.66)
    static let teal = GraphColor(r: 0.16, g: 0.69, b: 0.66)
    static let yellow = GraphColor(r: 0.89, g: 0.70, b: 0.17)
    static let gray = GraphColor(r: 0.56, g: 0.56, b: 0.59)

    static let palette: [GraphColor] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .yellow]

    static let named: [String: GraphColor] = [
        "blue": .blue, "orange": .orange, "green": .green, "red": .red, "purple": .purple, "violet": .purple,
        "pink": .pink, "teal": .teal, "cyan": .teal, "yellow": .yellow, "gold": .yellow, "gray": .gray, "grey": .gray,
    ]

    static func parse(_ any: Any?) -> GraphColor? {
        guard let s = (any as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if let c = named[s] { return c }
        let hex = s.hasPrefix("#") ? String(s.dropFirst()) : s
        guard hex.count == 6, let v = UInt32(hex, radix: 16) else { return nil }
        return GraphColor(r: Double(v >> 16 & 0xFF) / 255, g: Double(v >> 8 & 0xFF) / 255, b: Double(v & 0xFF) / 255)
    }
}

// MARK: - Reading the JSON

extension GraphSpec {
    /// Reads the JSON inside a <graph> tag. Nil when it isn't usable JSON at all; parts that don't make
    /// sense are skipped and listed in `problems`, so the rest still draws.
    static func parse(_ source: String) -> GraphSpec? {
        var text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") { // a code fence inside the tag
            text = text.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if let end = text.range(of: "```", options: .backwards) { text = String(text[..<end.lowerBound]) }
        }
        // Forgive trailing commas, the most common JSON slip.
        text = text.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var reader = Reader(root: root)
        return reader.read()
    }

    private struct Reader {
        let root: [String: Any]
        var spec = GraphSpec()
        var callable: Set<String> = []   // plots usable as functions: f(2)
        var plotNames: Set<String> = []
        var pointNames: Set<String> = []
        var valueNames: Set<String> = ["x", "t"]

        init(root: [String: Any]) {
            self.root = root
        }

        mutating func read() -> GraphSpec {
            spec.title = string(root["title"])
            spec.caption = string(root["caption"])
            spec.equal = root["equal"] as? Bool ?? false
            spec.axes = root["axes"] as? Bool ?? true

            // Names first, so expressions anywhere can refer to anything.
            for p in array(root["plots"]) {
                guard let name = string(p["name"]) else { continue }
                plotNames.insert(name)
                if p["y"] != nil || p["points"] != nil { callable.insert(name) }
            }
            for p in array(root["points"]) {
                guard let name = string(p["name"]) else { continue }
                pointNames.insert(name)
                valueNames.formUnion(["\(name).x", "\(name).y"])
            }
            readSliders()
            spec.x = axis(root["x"], "x")
            spec.y = axis(root["y"], "y")
            if let a = number(root["aspect"]) {
                spec.aspect = CGFloat(min(max(a, 0.35), 1.2))
            } else if spec.equal {
                let env = MathEnv(values: spec.initialValues)
                if let x0 = spec.x.min?.value(env), let x1 = spec.x.max?.value(env),
                   let y0 = spec.y.min?.value(env), let y1 = spec.y.max?.value(env),
                   x1 > x0, y1 > y0 {
                    spec.aspect = CGFloat(min(max((y1 - y0) / (x1 - x0), 0.45), 1.1))
                }
            }
            readPlots()
            readPoints()
            readLines()
            readAreas()
            readShapes()
            return spec
        }

        // MARK: Sections

        mutating func readSliders() {
            for (i, s) in array(root["sliders"]).prefix(4).enumerated() {
                guard let name = string(s["name"]), name.first?.isLetter == true, !name.contains("."),
                      MathExpr.builtins[name] == nil,
                      let lo = number(s["min"]), let hi = number(s["max"]), hi > lo else {
                    spec.problems.append("slider \(i + 1) needs a name, min and max")
                    continue
                }
                let start = number(s["value"]) ?? (lo...hi).clamp(0)
                spec.sliders.append(Slider(name: name, label: string(s["label"]) ?? name, min: lo, max: hi,
                                           value: (lo...hi).clamp(start), step: number(s["step"]).flatMap { $0 > 0 ? $0 : nil }))
                valueNames.insert(name)
            }
        }

        mutating func axis(_ any: Any?, _ which: String) -> Axis {
            var a = Axis()
            guard let d = any as? [String: Any] else { return a }
            a.label = string(d["label"])
            if let r = d["range"] as? [Any], r.count == 2 {
                a.min = expr(r[0], "\(which) range")
                a.max = expr(r[1], "\(which) range")
            }
            if let v = d["min"] { a.min = expr(v, "\(which) min") }
            if let v = d["max"] { a.max = expr(v, "\(which) max") }
            a.numbers = (d["numbers"] as? Bool) ?? (d["ticks"] as? Bool) ?? true
            return a
        }

        mutating func readPlots() {
            var paletteIndex = 0
            for (i, p) in array(root["plots"]).prefix(12).enumerated() {
                let what = "plot \(string(p["label"]) ?? string(p["name"]) ?? "\(i + 1)")"
                let kind: PlotKind
                if let y = p["y"] {
                    guard let e = expr(y, what) else { continue }
                    kind = .function(e)
                } else if let pts = p["points"] as? [Any] {
                    let coords = pts.prefix(200).compactMap { coord($0, what) }
                    guard coords.count >= 2 else { spec.problems.append("\(what) needs at least 2 points"); continue }
                    kind = .path(coords, smooth: p["smooth"] as? Bool ?? false)
                } else if let par = p["parametric"] as? [Any], par.count == 2 {
                    guard let fx = expr(par[0], what), let fy = expr(par[1], what) else { continue }
                    let range = p["t"] as? [Any]
                    let t0 = range?.first.flatMap { expr($0, what) } ?? .number(0)
                    let t1 = (range?.count == 2 ? range?[1] : nil).flatMap { expr($0, what) } ?? .number(2 * .pi)
                    kind = .parametric(x: fx, y: fy, from: t0, to: t1)
                } else if let x = p["x"] { // "x": 3 is a vertical line
                    if let e = expr(x, what) {
                        spec.lines.append(Line(kind: .vertical(e), label: string(p["label"]), dashed: p["dashed"] as? Bool ?? false,
                                               color: GraphColor.parse(p["color"])))
                    }
                    continue
                } else {
                    spec.problems.append("\(what) has no \"y\", \"points\" or \"parametric\"")
                    continue
                }
                var color = GraphColor.parse(p["color"])
                if color == nil {
                    color = GraphColor.palette[paletteIndex % GraphColor.palette.count]
                    paletteIndex += 1
                }
                spec.plots.append(Plot(name: string(p["name"]), label: string(p["label"]), kind: kind, color: color!,
                                       dashed: p["dashed"] as? Bool ?? false,
                                       from: p["from"].flatMap { expr($0, what) }, to: p["to"].flatMap { expr($0, what) }))
            }
        }

        mutating func readPoints() {
            for (i, p) in array(root["points"]).prefix(24).enumerated() {
                let what = "point \(string(p["label"]) ?? string(p["name"]) ?? "\(i + 1)")"
                let kind: PointKind
                if let pair = p["intersect"] as? [Any], pair.count == 2 {
                    guard let a = edge(pair[0], what), let b = edge(pair[1], what) else { continue }
                    kind = .intersect(a, b, near: p["near"].flatMap { expr($0, what) }, all: p["all"] as? Bool ?? false)
                } else if let on = string(p["on"]) {
                    guard callable.contains(on) else { spec.problems.append("\(what): no plot named “\(on)”"); continue }
                    guard let x = p["x"].flatMap({ expr($0, what) }) else { spec.problems.append("\(what) needs an x"); continue }
                    kind = .on(on, x)
                } else if let at = p["at"] as? [Any], at.count == 2 {
                    guard let x = expr(at[0], what), let y = expr(at[1], what) else { continue }
                    kind = .at(x, y)
                } else if let xv = p["x"], let yv = p["y"] {
                    guard let x = expr(xv, what), let y = expr(yv, what) else { continue }
                    kind = .at(x, y)
                } else {
                    spec.problems.append("\(what) needs x and y, \"intersect\" or \"on\"")
                    continue
                }
                var guides: Guides?
                if p["guides"] as? Bool == true {
                    guides = Guides(xLabel: nil, yLabel: nil)
                } else if let g = p["guides"] as? [Any] {
                    guides = Guides(xLabel: g.first.flatMap(string), yLabel: g.count > 1 ? string(g[1]) : nil)
                }
                spec.points.append(Point(name: string(p["name"]), label: string(p["label"]), kind: kind, guides: guides,
                                         hollow: p["hollow"] as? Bool ?? false, color: GraphColor.parse(p["color"])))
            }
        }

        mutating func readLines() {
            for (i, l) in array(root["lines"]).prefix(12).enumerated() {
                let what = "line \(string(l["label"]) ?? "\(i + 1)")"
                let kind: LineKind
                var dashedByDefault = false
                if let v = l["x"] {
                    guard let e = expr(v, what) else { continue }
                    kind = .vertical(e)
                    dashedByDefault = true
                } else if let v = l["y"] {
                    guard let e = expr(v, what) else { continue }
                    kind = .horizontal(e)
                    dashedByDefault = true
                } else if let f = string(l["tangent"]) {
                    guard callable.contains(f) else { spec.problems.append("\(what): no plot named “\(f)”"); continue }
                    guard let at = l["at"].flatMap({ expr($0, what) }) else { spec.problems.append("\(what) needs \"at\""); continue }
                    kind = .tangent(f, at: at)
                } else if let through = l["through"] as? [Any], through.count == 2 {
                    guard let a = coord(through[0], what), let b = coord(through[1], what) else { continue }
                    kind = .through(a, b)
                } else if let m = l["slope"], let pt = l["point"] {
                    guard let slope = expr(m, what), let c = coord(pt, what) else { continue }
                    kind = .slope(slope, through: c)
                } else {
                    spec.problems.append("\(what) needs \"x\", \"y\", \"tangent\", \"through\" or \"slope\"")
                    continue
                }
                spec.lines.append(Line(kind: kind, label: string(l["label"]), dashed: l["dashed"] as? Bool ?? dashedByDefault,
                                       color: GraphColor.parse(l["color"])))
            }
        }

        mutating func readAreas() {
            for (i, a) in array(root["areas"]).prefix(8).enumerated() {
                let what = "area \(string(a["label"]) ?? "\(i + 1)")"
                let top: Edge, bottom: Edge
                if let pair = a["between"] as? [Any], pair.count == 2 {
                    guard let t = edge(pair[0], what), let b = edge(pair[1], what) else { continue }
                    (top, bottom) = (t, b)
                } else if let u = a["under"] {
                    guard let t = edge(u, what) else { continue }
                    (top, bottom) = (t, .expr(.number(0)))
                } else {
                    spec.problems.append("\(what) needs \"between\" or \"under\"")
                    continue
                }
                let color = GraphColor.parse(a["color"]) ?? plotColor(top) ?? plotColor(bottom) ?? .orange
                spec.areas.append(Area(top: top, bottom: bottom, from: a["from"].flatMap { expr($0, what) },
                                       to: a["to"].flatMap { expr($0, what) }, label: string(a["label"]), color: color))
            }
        }

        mutating func readShapes() {
            for (i, s) in array(root["shapes"]).prefix(40).enumerated() {
                let what = "shape \(string(s["label"]) ?? "\(i + 1)")"
                let kind: ShapeKind
                if let pair = s["arrow"] as? [Any], pair.count == 2 {
                    guard let a = coord(pair[0], what), let b = coord(pair[1], what) else { continue }
                    kind = .arrow(a, b)
                } else if let pair = s["segment"] as? [Any], pair.count == 2 {
                    guard let a = coord(pair[0], what), let b = coord(pair[1], what) else { continue }
                    kind = .segment(a, b)
                } else if let pts = s["polygon"] as? [Any] {
                    let coords = pts.prefix(60).compactMap { coord($0, what) }
                    guard coords.count >= 3 else { spec.problems.append("\(what) needs 3+ corners"); continue }
                    kind = .polygon(coords)
                } else if let c = s["circle"] {
                    if let arr = c as? [Any], arr.count == 3 {
                        guard let x = expr(arr[0], what), let y = expr(arr[1], what), let r = expr(arr[2], what) else { continue }
                        kind = .circle(.pair(x, y), radius: r)
                    } else if let d = c as? [String: Any], let center = d["center"].flatMap({ coord($0, what) }),
                              let r = d["r"].flatMap({ expr($0, what) }) {
                        kind = .circle(center, radius: r)
                    } else {
                        spec.problems.append("\(what): circle is [x, y, r]")
                        continue
                    }
                } else if let b = s["box"] as? [Any], b.count == 4 {
                    guard let x = expr(b[0], what), let y = expr(b[1], what),
                          let w = expr(b[2], what), let h = expr(b[3], what) else { continue }
                    kind = .box(.pair(x, y), width: w, height: h)
                } else if let text = string(s["text"]) {
                    guard let at = s["at"].flatMap({ coord($0, what) }) else { spec.problems.append("\(what) needs \"at\""); continue }
                    kind = .text(text, at)
                } else {
                    spec.problems.append("\(what) isn't a shape Margin knows")
                    continue
                }
                spec.shapes.append(Shape(kind: kind, label: string(s["label"]), color: GraphColor.parse(s["color"]),
                                         dashed: s["dashed"] as? Bool ?? false, filled: s["fill"] as? Bool ?? false))
            }
        }

        // MARK: Values

        func plotColor(_ e: Edge) -> GraphColor? {
            guard case .plot(let name) = e else { return nil }
            return spec.plots.first { $0.name == name }?.color
        }

        /// JSON true/false (Swift would also call the numbers 0 and 1 "Bool").
        static func isBool(_ any: Any?) -> Bool {
            guard let n = any as? NSNumber else { return false }
            return CFGetTypeID(n) == CFBooleanGetTypeID()
        }

        func array(_ any: Any?) -> [[String: Any]] {
            (any as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
        }

        func string(_ any: Any?) -> String? {
            if let s = any as? String {
                let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            if let n = any as? NSNumber, !Self.isBool(any) { return MathFormat.short(n.doubleValue) }
            return nil
        }

        /// A constant: 3, "2*pi", "-1/2".
        mutating func number(_ any: Any?) -> Double? {
            if let n = any as? NSNumber, !Self.isBool(any) { return n.doubleValue }
            guard let s = any as? String, let e = try? MathExpr.parse(s) else { return nil }
            let v = e.value(MathEnv())
            return v.isFinite ? v : nil
        }

        /// An expression (number or string). Unknown names are reported and the part is skipped.
        mutating func expr(_ any: Any?, _ what: String) -> MathExpr? {
            if let n = any as? NSNumber, !Self.isBool(any) { return .number(n.doubleValue) }
            guard let s = any as? String else {
                spec.problems.append("\(what): expected a number or an expression")
                return nil
            }
            do {
                let e = try MathExpr.parse(s, functions: callable)
                let unknown = e.names.subtracting(valueNames).subtracting(callable)
                    .filter { MathExpr.constants[$0] == nil }
                if let name = unknown.sorted().first {
                    spec.problems.append("\(what): unknown name “\(name)” in “\(s)”")
                    return nil
                }
                return e
            } catch {
                spec.problems.append("\(what): \(error) in “\(s)”")
                return nil
            }
        }

        mutating func edge(_ any: Any?, _ what: String) -> Edge? {
            if let s = any as? String, plotNames.contains(s.trimmingCharacters(in: .whitespaces)) {
                return .plot(s.trimmingCharacters(in: .whitespaces))
            }
            return expr(any, what).map { .expr($0) }
        }

        mutating func coord(_ any: Any?, _ what: String) -> Coord? {
            if let s = any as? String, pointNames.contains(s) { return .point(s) }
            guard let pair = any as? [Any], pair.count == 2,
                  let x = expr(pair[0], what), let y = expr(pair[1], what) else {
                spec.problems.append("\(what): a position is [x, y] or a point's name")
                return nil
            }
            return .pair(x, y)
        }
    }
}

extension ClosedRange where Bound == Double {
    func clamp(_ v: Double) -> Double { Swift.min(Swift.max(v, lowerBound), upperBound) }
    var span: Double { upperBound - lowerBound }
}

// MARK: - Computing a graph for the current slider values

/// Everything to draw, in graph units, for one set of slider values.
struct GraphScene {
    struct Curve {
        let label: String?
        let color: GraphColor
        let dashed: Bool
        let segments: [[CGPoint]]
    }

    struct Dot {
        let label: String?
        let at: CGPoint
        let hollow: Bool
        let color: GraphColor?
        let guides: GraphSpec.Guides?
    }

    struct Region {
        let polygon: [CGPoint]
        let label: String?
        let labelAt: CGPoint
        let color: GraphColor
    }

    struct Stroke {
        let from: CGPoint
        let to: CGPoint
        let label: String?
        let dashed: Bool
        let color: GraphColor?
        let arrow: Bool
        /// Reference lines run across the whole graph and are labeled at their end.
        let infinite: Bool
    }

    enum Figure {
        case polygon([CGPoint], label: String?, color: GraphColor?, dashed: Bool, filled: Bool)
        case circle(center: CGPoint, radius: Double, label: String?, color: GraphColor?, dashed: Bool, filled: Bool)
        case box(CGRect, label: String?, color: GraphColor?, dashed: Bool)
        case text(String, at: CGPoint, color: GraphColor?)
    }

    /// A curve that can be read at any x, for the hover readout.
    struct Reading {
        let label: String
        let color: GraphColor
        let value: (Double) -> Double
    }

    var xRange: ClosedRange<Double>
    var yRange: ClosedRange<Double>
    var curves: [Curve] = []
    var dots: [Dot] = []
    var regions: [Region] = []
    var strokes: [Stroke] = []
    var figures: [Figure] = []
    var readings: [Reading] = []
    /// Kept alive for `readings`, whose closures read from it.
    let env: MathEnv

    /// `plotSize` (in points) is only needed for equal scaling.
    static func build(_ spec: GraphSpec, values: [String: Double], plotSize: CGSize) -> GraphScene {
        let env = MathEnv(values: values)
        var functions: [String: (Double) -> Double] = [:]
        var paths: [String: [CGPoint]] = [:]

        func resolve(_ c: GraphSpec.Coord) -> CGPoint? {
            switch c {
            case .pair(let x, let y):
                let p = CGPoint(x: x.value(env), y: y.value(env))
                return p.x.isFinite && p.y.isFinite ? p : nil
            case .point(let name):
                let p = CGPoint(x: env.value(of: "\(name).x"), y: env.value(of: "\(name).y"))
                return p.x.isFinite && p.y.isFinite ? p : nil
            }
        }

        // Curves become functions others can call: f(2), and intersections and areas.
        for plot in spec.plots {
            guard let name = plot.name else { continue }
            let lo = plot.from?.value(env) ?? -.infinity, hi = plot.to?.value(env) ?? .infinity
            switch plot.kind {
            case .function(let e):
                functions[name] = { [unowned env] x in
                    guard x >= lo - 1e-12, x <= hi + 1e-12 else { return .nan }
                    return env.evaluate(e, setting: "x", to: x)
                }
            case .path(let coords, let smooth):
                let pts = coords.compactMap(resolve)
                let line = smooth ? Self.spline(pts) : pts
                paths[name] = line
                functions[name] = { x in Self.interpolate(line, at: x) }
            case .parametric:
                continue
            }
        }
        env.functions = functions

        func edgeValue(_ e: GraphSpec.Edge) -> (Double) -> Double {
            switch e {
            case .plot(let name): return { [unowned env] x in env.call(name, x) }
            case .expr(let ex): return { [unowned env] x in env.evaluate(ex, setting: "x", to: x) }
            }
        }

        // Fixed positions (paths, given points, shapes, parametric curves) size the graph when no range is given.
        var xs: [Double] = [], ys: [Double] = []
        func note(_ p: CGPoint?) {
            guard let p else { return }
            xs.append(Double(p.x))
            ys.append(Double(p.y))
        }
        for plot in spec.plots {
            switch plot.kind {
            case .function: continue
            case .path(let coords, _): coords.map(resolve).forEach(note)
            case .parametric(let fx, let fy, let t0, let t1):
                guard let ts = Self.span(t0.value(env), t1.value(env)) else { continue }
                for t in Self.samples(ts, 120) {
                    note(CGPoint(x: env.evaluate(fx, setting: "t", to: t), y: env.evaluate(fy, setting: "t", to: t)))
                }
            }
        }
        for p in spec.points { if case .at(let x, let y) = p.kind { note(CGPoint(x: x.value(env), y: y.value(env))) } }
        for shape in spec.shapes {
            switch shape.kind {
            case .segment(let a, let b), .arrow(let a, let b): [a, b].map(resolve).forEach(note)
            case .polygon(let cs): cs.map(resolve).forEach(note)
            case .circle(let c, let r):
                if let p = resolve(c), case let rv = r.value(env), rv.isFinite {
                    note(CGPoint(x: Double(p.x) - rv, y: Double(p.y) - rv))
                    note(CGPoint(x: Double(p.x) + rv, y: Double(p.y) + rv))
                }
            case .box(let c, let w, let h):
                if let p = resolve(c), case let wv = w.value(env), case let hv = h.value(env), wv.isFinite, hv.isFinite {
                    note(CGPoint(x: Double(p.x) - wv / 2, y: Double(p.y) - hv / 2))
                    note(CGPoint(x: Double(p.x) + wv / 2, y: Double(p.y) + hv / 2))
                }
            case .text(_, let c): note(resolve(c))
            }
        }
        var xRange = Self.range(given: spec.x, auto: xs.filter(\.isFinite), fallback: -10...10, env: env)

        // Points (in order, so later parts can use E.x and E.y).
        var dots: [Dot] = []
        for point in spec.points {
            var spots: [CGPoint] = []
            switch point.kind {
            case .at(let x, let y):
                spots = [CGPoint(x: x.value(env), y: y.value(env))]
            case .on(let f, let x):
                let xv = x.value(env)
                spots = [CGPoint(x: xv, y: env.call(f, xv))]
            case .intersect(let a, let b, let near, let all):
                let fa = edgeValue(a), fb = edgeValue(b)
                var roots = Self.crossings(of: { fa($0) - fb($0) }, in: xRange)
                if roots.isEmpty {
                    roots = Self.crossings(of: { fa($0) - fb($0) },
                                           in: (xRange.lowerBound - xRange.span)...(xRange.upperBound + xRange.span))
                }
                if let near = near?.value(env), near.isFinite, !all {
                    roots = roots.min { abs($0 - near) < abs($1 - near) }.map { [$0] } ?? []
                } else if !all {
                    roots = Array(roots.prefix(1))
                }
                spots = roots.map { CGPoint(x: $0, y: fa($0)) }
            }
            spots = spots.filter { $0.x.isFinite && $0.y.isFinite }
            if let name = point.name {
                env.values["\(name).x"] = spots.first.map { Double($0.x) } ?? .nan
                env.values["\(name).y"] = spots.first.map { Double($0.y) } ?? .nan
            }
            for s in spots {
                dots.append(Dot(label: point.label, at: s, hollow: point.hollow, color: point.color, guides: point.guides))
            }
        }

        // Y range: as given, else fitted to what's drawn.
        ys += dots.map { Double($0.at.y) }
        for plot in spec.plots {
            guard case .function(let e) = plot.kind else { continue }
            let f = plot.name.flatMap { functions[$0] } ?? { x in env.evaluate(e, setting: "x", to: x) }
            ys += Self.samples(xRange, 120).map(f)
        }
        var yRange = Self.range(given: spec.y, auto: Self.trimmed(ys.filter(\.isFinite)), fallback: -10...10, env: env)

        // Same scale on both axes: grow whichever range is too tight for the drawing's shape.
        if spec.equal, plotSize.width > 0, plotSize.height > 0 {
            let perPointX = xRange.span / plotSize.width, perPointY = yRange.span / plotSize.height
            if perPointX > perPointY {
                let half = perPointX * plotSize.height / 2, mid = (yRange.lowerBound + yRange.upperBound) / 2
                yRange = (mid - half)...(mid + half)
            } else {
                let half = perPointY * plotSize.width / 2, mid = (xRange.lowerBound + xRange.upperBound) / 2
                xRange = (mid - half)...(mid + half)
            }
        }

        var scene = GraphScene(xRange: xRange, yRange: yRange, env: env)
        scene.curves = []
        scene.dots = dots
        let band = (yRange.lowerBound - yRange.span)...(yRange.upperBound + yRange.span)

        // Curves.
        for plot in spec.plots {
            var segments: [[CGPoint]] = []
            switch plot.kind {
            case .function(let e):
                let f = plot.name.flatMap { functions[$0] } ?? { [unowned env] x in env.evaluate(e, setting: "x", to: x) }
                let lo = max(xRange.lowerBound, plot.from?.value(env) ?? -.infinity)
                let hi = min(xRange.upperBound, plot.to?.value(env) ?? .infinity)
                if lo < hi {
                    let xs = Self.samples(lo...hi, 480)
                    segments = Self.segments(xs.map { CGPoint(x: $0, y: f($0)) }, band: band)
                }
                if let name = plot.name, let label = plot.label ?? plot.name {
                    scene.readings.append(Reading(label: label, color: plot.color, value: { [unowned env] in env.call(name, $0) }))
                } else if plot.name == nil {
                    scene.readings.append(Reading(label: plot.label ?? "y", color: plot.color, value: f))
                }
            case .path(let coords, let smooth):
                if let name = plot.name, let line = paths[name] {
                    segments = [line]
                } else {
                    let pts = coords.compactMap(resolve)
                    segments = [smooth ? Self.spline(pts) : pts]
                }
            case .parametric(let fx, let fy, let t0, let t1):
                if let ts = Self.span(t0.value(env), t1.value(env)) {
                    let pts = Self.samples(ts, 480).map {
                        CGPoint(x: env.evaluate(fx, setting: "t", to: $0), y: env.evaluate(fy, setting: "t", to: $0))
                    }
                    segments = Self.segments(pts, band: band)
                }
            }
            scene.curves.append(Curve(label: plot.label, color: plot.color, dashed: plot.dashed,
                                      segments: segments.filter { $0.count >= 2 }))
        }

        // Reference lines.
        let far = 4 * max(xRange.span, yRange.span)
        func across(_ p: CGPoint, slope m: Double) -> (CGPoint, CGPoint) {
            (CGPoint(x: Double(p.x) - far, y: Double(p.y) - m * far), CGPoint(x: Double(p.x) + far, y: Double(p.y) + m * far))
        }
        for line in spec.lines {
            var ends: (CGPoint, CGPoint)?
            switch line.kind {
            case .vertical(let e):
                let v = e.value(env)
                if v.isFinite { ends = (CGPoint(x: v, y: yRange.lowerBound - far), CGPoint(x: v, y: yRange.upperBound + far)) }
            case .horizontal(let e):
                let v = e.value(env)
                if v.isFinite { ends = (CGPoint(x: xRange.lowerBound - far, y: v), CGPoint(x: xRange.upperBound + far, y: v)) }
            case .tangent(let f, let at):
                let a = at.value(env), h = max(1e-7, xRange.span * 1e-5)
                let y0 = env.call(f, a), m = (env.call(f, a + h) - env.call(f, a - h)) / (2 * h)
                if a.isFinite, y0.isFinite, m.isFinite { ends = across(CGPoint(x: a, y: y0), slope: m) }
            case .through(let c1, let c2):
                if let p = resolve(c1), let q = resolve(c2), p != q {
                    if abs(q.x - p.x) < 1e-12 {
                        ends = (CGPoint(x: p.x, y: yRange.lowerBound - far), CGPoint(x: p.x, y: yRange.upperBound + far))
                    } else {
                        ends = across(p, slope: Double((q.y - p.y) / (q.x - p.x)))
                    }
                }
            case .slope(let m, let c):
                let mv = m.value(env)
                if let p = resolve(c), mv.isFinite { ends = across(p, slope: mv) }
            }
            if let (a, b) = ends {
                scene.strokes.append(Stroke(from: a, to: b, label: line.label, dashed: line.dashed, color: line.color,
                                            arrow: false, infinite: true))
            }
        }

        // Shaded areas.
        for area in spec.areas {
            let top = edgeValue(area.top), bottom = edgeValue(area.bottom)
            let a = max(xRange.lowerBound, area.from?.value(env) ?? xRange.lowerBound)
            let b = min(xRange.upperBound, area.to?.value(env) ?? xRange.upperBound)
            guard a.isFinite, b.isFinite, a < b else { continue }
            var upper: [CGPoint] = [], lower: [CGPoint] = []
            for x in Self.samples(a...b, 200) {
                let t = top(x), u = bottom(x)
                guard t.isFinite, u.isFinite else { continue }
                upper.append(CGPoint(x: x, y: band.clamp(t)))
                lower.append(CGPoint(x: x, y: band.clamp(u)))
            }
            let polygon = upper + lower.reversed()
            guard polygon.count >= 3 else { continue }
            scene.regions.append(Region(polygon: polygon, label: area.label, labelAt: Self.centroid(polygon), color: area.color))
        }

        // Shapes.
        for shape in spec.shapes {
            switch shape.kind {
            case .segment(let a, let b), .arrow(let a, let b):
                guard let p = resolve(a), let q = resolve(b) else { continue }
                var isArrow = false
                if case .arrow = shape.kind { isArrow = true }
                scene.strokes.append(Stroke(from: p, to: q, label: shape.label, dashed: shape.dashed, color: shape.color,
                                            arrow: isArrow, infinite: false))
            case .polygon(let cs):
                let pts = cs.compactMap(resolve)
                guard pts.count >= 3 else { continue }
                scene.figures.append(.polygon(pts, label: shape.label, color: shape.color, dashed: shape.dashed, filled: shape.filled))
            case .circle(let c, let r):
                guard let p = resolve(c) else { continue }
                let rv = r.value(env)
                guard rv.isFinite, rv > 0 else { continue }
                scene.figures.append(.circle(center: p, radius: rv, label: shape.label, color: shape.color,
                                             dashed: shape.dashed, filled: shape.filled))
            case .box(let c, let w, let h):
                guard let p = resolve(c) else { continue }
                let wv = w.value(env), hv = h.value(env)
                guard wv.isFinite, hv.isFinite, wv > 0, hv > 0 else { continue }
                scene.figures.append(.box(CGRect(x: Double(p.x) - wv / 2, y: Double(p.y) - hv / 2, width: wv, height: hv),
                                          label: shape.label, color: shape.color, dashed: shape.dashed))
            case .text(let s, let c):
                guard let p = resolve(c) else { continue }
                scene.figures.append(.text(s, at: p, color: shape.color))
            }
        }
        return scene
    }

    // MARK: Math helpers

    /// a…b in either order, or nil if either end is undefined or they're equal.
    static func span(_ a: Double, _ b: Double) -> ClosedRange<Double>? {
        guard a.isFinite, b.isFinite, a != b else { return nil }
        return min(a, b)...max(a, b)
    }

    static func samples(_ r: ClosedRange<Double>, _ n: Int) -> [Double] {
        guard r.lowerBound.isFinite, r.upperBound.isFinite, n > 1 else { return [] }
        return (0..<n).map { r.lowerBound + r.span * Double($0) / Double(n - 1) }
    }

    /// Given min/max win; missing ones come from what's drawn (padded), else the fallback.
    static func range(given axis: GraphSpec.Axis, auto values: [Double], fallback: ClosedRange<Double>,
                      env: MathEnv) -> ClosedRange<Double> {
        var lo = axis.min?.value(env), hi = axis.max?.value(env)
        if lo?.isFinite != true { lo = nil }
        if hi?.isFinite != true { hi = nil }
        if lo == nil || hi == nil {
            if let vmin = values.min(), let vmax = values.max(), vmax > vmin {
                var a = vmin, b = vmax
                // Start at 0 when the data is close to it (most textbook graphs do).
                if a > 0, a < 0.3 * (b - a) { a = 0 }
                if b < 0, -b < 0.3 * (b - a) { b = 0 }
                let pad = (b - a) * 0.08
                lo = lo ?? (a == 0 ? 0 : a - pad)
                hi = hi ?? (b == 0 ? 0 : b + pad)
            } else if let v = values.first {
                lo = lo ?? v - 5
                hi = hi ?? v + 5
            }
        }
        let l = lo ?? fallback.lowerBound, h = hi ?? fallback.upperBound
        if h > l { return l...h }
        if l > h { return h...l }
        return (l - 1)...(l + 1)
    }

    /// Ignores runaway values (like near an asymptote) when fitting the y range.
    static func trimmed(_ values: [Double]) -> [Double] {
        guard values.count > 20 else { return values }
        let sorted = values.sorted()
        let lo = sorted[Int(Double(sorted.count) * 0.02)], hi = sorted[Int(Double(sorted.count) * 0.98)]
        let spread = max(hi - lo, 1e-9)
        return values.filter { $0 >= lo - spread * 0.25 && $0 <= hi + spread * 0.25 }
    }

    /// Where h crosses zero, sorted (sign changes refined by bisection; jumps over asymptotes ignored).
    static func crossings(of h: (Double) -> Double, in r: ClosedRange<Double>) -> [Double] {
        let xs = samples(r, 801)
        var roots: [Double] = []
        var px = xs.first ?? 0, ph = h(px)
        if ph == 0 { roots.append(px) }
        for x in xs.dropFirst() {
            let hx = h(x)
            defer { px = x; ph = hx }
            guard ph.isFinite, hx.isFinite else { continue }
            if hx == 0 {
                roots.append(x)
            } else if ph != 0, (ph < 0) != (hx < 0) {
                var lo = px, hi = x, hlo = ph
                for _ in 0..<64 {
                    let mid = (lo + hi) / 2, hm = h(mid)
                    guard hm.isFinite else { break }
                    if (hm < 0) == (hlo < 0) { lo = mid; hlo = hm } else { hi = mid }
                }
                let root = (lo + hi) / 2, value = h(root)
                let scale = max(1, abs(ph), abs(hx))
                if value.isFinite, abs(value) < 1e-6 * scale + 1e-9 { roots.append(root) }
            }
        }
        var unique: [Double] = []
        for r in roots where !unique.contains(where: { abs($0 - r) < 1e-7 * max(1, abs(r)) }) { unique.append(r) }
        return unique
    }

    /// Splits sampled points into drawable runs: breaks at undefined values and at jumps across an
    /// asymptote, and pulls far-off points back to `band` along the curve so lines stay true.
    static func segments(_ pts: [CGPoint], band: ClosedRange<Double>) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var current: [CGPoint] = []
        func flush() {
            if current.count >= 2 { out.append(current) }
            current = []
        }
        func clip(_ p: CGPoint, toward q: CGPoint) -> CGPoint {
            // The point on p→q where it meets the band edge q is outside of.
            let edge = Double(q.y) > band.upperBound ? band.upperBound : band.lowerBound
            let t = (edge - Double(p.y)) / Double(q.y - p.y)
            return CGPoint(x: Double(p.x) + t * Double(q.x - p.x), y: edge)
        }
        var prev: CGPoint?
        for p in pts {
            guard p.x.isFinite, p.y.isFinite else {
                flush()
                prev = nil
                continue
            }
            defer { prev = p }
            let inside = band.contains(Double(p.y))
            guard let q = prev else {
                if inside { current = [p] }
                continue
            }
            let prevInside = band.contains(Double(q.y))
            switch (prevInside, inside) {
            case (true, true):
                if current.isEmpty { current = [q] }
                current.append(p)
            case (true, false):
                if current.isEmpty { current = [q] }
                current.append(clip(q, toward: p))
                flush()
            case (false, true):
                current = [clip(p, toward: q), p]
            case (false, false):
                // Both outside: either the same side (nothing visible) or a jump across an asymptote.
                flush()
            }
        }
        flush()
        return out
    }

    /// The y on a polyline at x (the first piece that spans x), or NaN off its ends.
    static func interpolate(_ line: [CGPoint], at x: Double) -> Double {
        guard line.count >= 2 else { return .nan }
        for (a, b) in zip(line, line.dropFirst()) {
            let lo = min(Double(a.x), Double(b.x)), hi = max(Double(a.x), Double(b.x))
            guard x >= lo - 1e-12, x <= hi + 1e-12 else { continue }
            if hi - lo < 1e-12 { return Double(a.y) }
            let t = (x - Double(a.x)) / Double(b.x - a.x)
            return Double(a.y) + t * Double(b.y - a.y)
        }
        return .nan
    }

    /// A smooth curve through the points (Catmull-Rom).
    static func spline(_ pts: [CGPoint]) -> [CGPoint] {
        guard pts.count >= 3 else { return pts }
        var out: [CGPoint] = []
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)], p1 = pts[i], p2 = pts[i + 1], p3 = pts[min(i + 2, pts.count - 1)]
            for s in 0..<16 {
                let t = CGFloat(s) / 16, t2 = t * t, t3 = t2 * t
                func blend(_ a: CGFloat, _ b: CGFloat, _ c: CGFloat, _ d: CGFloat) -> CGFloat {
                    0.5 * (2 * b + (-a + c) * t + (2 * a - 5 * b + 4 * c - d) * t2 + (-a + 3 * b - 3 * c + d) * t3)
                }
                out.append(CGPoint(x: blend(p0.x, p1.x, p2.x, p3.x), y: blend(p0.y, p1.y, p2.y, p3.y)))
            }
        }
        out.append(pts[pts.count - 1])
        return out
    }

    static func centroid(_ polygon: [CGPoint]) -> CGPoint {
        var area: CGFloat = 0, cx: CGFloat = 0, cy: CGFloat = 0
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) {
            let cross = a.x * b.y - b.x * a.y
            area += cross
            cx += (a.x + b.x) * cross
            cy += (a.y + b.y) * cross
        }
        if abs(area) < 1e-12 {
            let n = CGFloat(polygon.count)
            return CGPoint(x: polygon.map(\.x).reduce(0, +) / n, y: polygon.map(\.y).reduce(0, +) / n)
        }
        return CGPoint(x: cx / (3 * area), y: cy / (3 * area))
    }

    /// The polygon's area (for tests).
    static func area(_ polygon: [CGPoint]) -> Double {
        var s: CGFloat = 0
        for (a, b) in zip(polygon, polygon.dropFirst() + [polygon[0]]) { s += a.x * b.y - b.x * a.y }
        return abs(Double(s)) / 2
    }
}
