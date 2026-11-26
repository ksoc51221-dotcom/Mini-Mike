// Thinking orbs: a Swift port of the geometry engine from "thinking-orbs" by Jakub Antalik
// (https://github.com/Jakubantalik/thinking-orbs, commit de85557, library 0.3.1).
//
// MIT License
//
// Copyright (c) 2026 Jakub Antalik
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
//
// A copy of the licence and the spec/golden files sit in third_party/thinking-orbs. The port is checked dot by dot
// against orbs-golden.json (`Merlin --orbtest`). Transcription rules: JS `Math.round` is `floor(x + 0.5)`, `%` is
// `truncatingRemainder`, `?? default` keeps an explicit 0, and the depth sort is stable (ties keep insertion order).

import Foundation

enum Orb {
    /// The nine shipped states; each one picks a mode painter.
    enum State: String, CaseIterable {
        case working, searching, solving, listening, connecting, weaving, composing, breathing, shaping

        var mode: Mode {
            switch self {
            case .working: .orbits
            case .searching: .globe
            case .solving: .rubik
            case .listening: .wave
            case .connecting: .web
            case .weaving: .braid
            case .composing: .ribbon
            case .breathing: .ring
            case .shaping: .morph
            }
        }

        /// Spoken label, from the spec's a11y strings.
        var label: String {
            switch self {
            case .working: "Working"
            case .searching: "Searching"
            case .solving: "Solving"
            case .listening: "Listening"
            case .connecting: "Connecting"
            case .weaving: "Weaving"
            case .composing: "Composing"
            case .breathing: "Breathing"
            case .shaping: "Shaping"
            }
        }
    }

    enum Mode: String { case orbits, globe, rubik, wave, web, braid, ribbon, ring, morph }

    /// The two tuned sizes. Other point sizes draw one of these, scaled.
    enum Size: Int, CaseIterable { case large = 64, small = 20 }

    typealias Opts = [String: Double]

    struct Dot: Equatable { var x, y, z, r, white, a: Double }
    struct Line: Equatable { var x1, y1, x2, y2, white, a, w: Double }
    struct Frame { var dots: [Dot]; var lines: [Line] }

    struct Resolved { let mode: Mode; let speed: Double; let opts: Opts }

    // MARK: - Shared primitives (core.ts)

    @inline(__always) static func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
    @inline(__always) static func lerp(_ a: Double, _ b: Double, _ f: Double) -> Double { a + (b - a) * f }
    @inline(__always) static func frac(_ x: Double) -> Double { x - x.rounded(.down) }

    static func hashD(_ a: Double, _ b: Double) -> Double {
        let h = sin(a * 12.9898 + b * 78.233) * 43758.5453
        return h - h.rounded(.down)
    }

    static func vnoise(_ x: Double, _ y: Double) -> Double {
        let xi = x.rounded(.down), yi = y.rounded(.down)
        var fx = x - xi, fy = y - yi
        fx = fx * fx * (3 - 2 * fx)
        fy = fy * fy * (3 - 2 * fy)
        let a = hashD(xi, yi), b = hashD(xi + 1, yi), c = hashD(xi, yi + 1), d = hashD(xi + 1, yi + 1)
        return a + (b - a) * fx + (c - a) * fy + (a - b - c + d) * fx * fy
    }

    static func fibDir(_ i: Int, _ n: Int) -> (Double, Double, Double) {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        let y = 1 - (2 * (Double(i) + 0.5)) / Double(n)
        let rad = (1 - y * y).squareRoot()
        let a = Double(i) * golden
        return (rad * cos(a), y, rad * sin(a))
    }

    static func angleDelta(_ a: Double, _ b: Double) -> Double { atan2(sin(a - b), cos(a - b)) }

    struct Proj {
        let st, ct, sy, cyw, cx, cy, scale: Double
        init(yaw: Double, tilt: Double, cx: Double, cy: Double, scale: Double) {
            st = sin(tilt); ct = cos(tilt); sy = sin(yaw); cyw = cos(yaw)
            self.cx = cx; self.cy = cy; self.scale = scale
        }
        @inline(__always) func callAsFunction(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
            let x1 = x * cyw + z * sy
            let z1 = -x * sy + z * cyw
            let y1 = y * ct - z1 * st
            let z2 = y * st + z1 * ct
            return (cx + x1 * scale, cy - y1 * scale, z2)
        }
    }

    static func radiusScale(_ size: Double, _ pow: Double) -> Double { Foundation.pow(size / 300, pow) }

    /// Cull invisible marks, clamp radii to the mode floor, stable z-sort far to near.
    static func finalize(_ dots: [Dot], _ lines: [Line], rMin: Double?) -> Frame {
        let floor = rMin ?? 0.3
        var visible: [(Int, Dot)] = []
        visible.reserveCapacity(dots.count)
        for (i, var d) in dots.enumerated() where d.a >= 0.02 {
            d.r = max(floor, d.r)
            visible.append((i, d))
        }
        visible.sort { $0.1.z != $1.1.z ? $0.1.z < $1.1.z : $0.0 < $1.0 }
        return Frame(dots: visible.map(\.1), lines: lines.filter { $0.a >= 0.02 })
    }

    // MARK: - Profiles and presets (profiles.ts, presets.ts)

    private static let countPairs: [(String, String)] = [("latRings", "lonDensity"), ("rings", "lonDensity"), ("lanes", "segs")]
    private static let countKeys = ["orbitN", "ghostN", "nodeN", "strandN", "signals"]
    private static let radiusKeys = ["rBase", "rDepth", "rActive", "rDot", "ghostR", "partR", "partRDepth", "nodeR", "nodeRDepth"]

    static func scaleCounts(_ opts: Opts, _ scale: Double) -> Opts {
        var out = opts
        var done = Set<String>()
        let rt = scale.squareRoot()
        for (a, b) in countPairs {
            if let va = out[a], let vb = out[b], !done.contains(a), !done.contains(b) {
                out[a] = max(2, jsRound(va * rt))
                out[b] = max(2, jsRound(vb * rt))
                done.insert(a); done.insert(b)
            }
        }
        for k in countKeys {
            if let v = out[k], v != 0, !done.contains(k) { out[k] = max(1, jsRound(v * scale)) }
        }
        if let v = out["iconD"] { out["iconD"] = max(0.02, v * scale) }
        return out
    }

    static func scaleRadii(_ opts: Opts, _ scale: Double) -> Opts {
        var out = opts
        for k in radiusKeys { if let v = out[k] { out[k] = v * scale } }
        out["rSizeMul"] = (out["rSizeMul"] ?? 1) * scale
        return out
    }

    static let baseProfiles: [Mode: Opts] = [
        .globe: ["latRings": 17, "lonDensity": 44, "rBase": 0.6, "rDepth": 1.7, "rBoost": 1.0, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
        .orbits: ["orbitN": 12, "ghostN": 40, "ghostR": 0.9, "ghostA": 0.5, "particles": 3, "partR": 1.2, "partRDepth": 1.6, "rsPow": 0.6, "rMin": 0.3],
        .rubik: ["latRings": 15, "lonDensity": 40, "moveCount": 14, "rBase": 0.6, "rDepth": 1.7, "rActive": 0.3, "inkFar": 0.62, "inkSpan": 0.54, "rsPow": 0.6, "rMin": 0.3],
        .wave: ["rings": 15, "lonDensity": 40, "rBase": 0.6, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
        .web: ["nodeN": 30, "thr": 0.72, "signals": 5, "nodeR": 1.4, "nodeRDepth": 1.8, "lineW": 0.8, "rsPow": 0.6, "rMin": 0.3],
        .braid: ["strandN": 52, "turns": 3.0, "ghostN": 150, "rBase": 1.2, "rDepth": 1.8, "rsPow": 0.6, "rMin": 0.3],
        .ribbon: ["lanes": 5, "segs": 88, "ghostN": 150, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
        .ring: ["lanes": 5, "segs": 88, "ghostN": 0, "faceOn": 1, "rBase": 1.1, "rDepth": 1.7, "rsPow": 0.6, "rMin": 0.3],
        .morph: ["rDot": 0.021, "iconD": 1, "rMin": 0.25],
    ]

    struct Preset { let speed, count, size: Double; var extra: Opts = [:] }

    static let presets: [Mode: [Size: Preset]] = [
        .orbits: [.large: .init(speed: 1.885, count: 1, size: 1), .small: .init(speed: 3.9, count: 0.238, size: 2.4)],
        .globe: [.large: .init(speed: 2.015, count: 0.42, size: 1.15, extra: ["scanMul": 4.08, "dimBase": 0.45]),
                 .small: .init(speed: 2.665, count: 0.105, size: 1.75, extra: ["scanMul": 4.335, "dimBase": 0.45])],
        .rubik: [.large: .init(speed: 1.82, count: 0.35, size: 1.05), .small: .init(speed: 1.95, count: 0.088, size: 1.9)],
        .wave: [.large: .init(speed: 4.388, count: 0.341, size: 1), .small: .init(speed: 3.998, count: 0.105, size: 1.6)],
        .web: [.large: .init(speed: 3.315, count: 1.35, size: 0.95), .small: .init(speed: 6.63, count: 0.25, size: 1.52)],
        .braid: [.large: .init(speed: 1.625, count: 0.5, size: 1), .small: .init(speed: 2.75, count: 0.1125, size: 1.36)],
        .ribbon: [.large: .init(speed: 2.34, count: 0.25, size: 0.85, extra: ["spin": 0, "bandMul": 3.9, "wobMul": 1]),
                  .small: .init(speed: 3.12, count: 0.051, size: 1.073, extra: ["spin": 0, "bandMul": 4.94, "wobMul": 1])],
        .ring: [.large: .init(speed: 3.24, count: 0.25, size: 0.956, extra: ["spin": 0, "bandMul": 3.627, "wobMul": 0.368]),
                .small: .init(speed: 3.78, count: 0.028, size: 1.622, extra: ["spin": 0, "bandMul": 3.968, "wobMul": 0.565])],
        .morph: [.large: .init(speed: 2.405, count: 0.702, size: 0.395, extra: ["spread": 1.45]),
                 .small: .init(speed: 2.08, count: 0.53, size: 1.011, extra: ["spread": 1.45])],
    ]

    nonisolated(unsafe) private static var cache: [String: Resolved] = [:]
    private static let cacheLock = NSLock()

    static func resolve(_ state: State, _ size: Size) -> Resolved {
        let key = "\(state.rawValue)-\(size.rawValue)"
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let hit = cache[key] { return hit }
        let mode = state.mode
        let preset = presets[mode]![size]!
        var opts = baseProfiles[mode]!
        if preset.count != 1 { opts = scaleCounts(opts, preset.count) }
        if preset.size != 1 { opts = scaleRadii(opts, preset.size) }
        opts.merge(preset.extra) { _, new in new }
        let r = Resolved(mode: mode, speed: preset.speed, opts: opts)
        cache[key] = r
        return r
    }

    /// Geometry for one instant at `size` points; `t` is already speed-scaled.
    static func frame(_ mode: Mode, size: Double, t: Double, opts o: Opts) -> Frame {
        switch mode {
        case .orbits: orbits(size, t, o)
        case .globe: globe(size, t, o)
        case .rubik: rubik(size, t, o)
        case .wave: wave(size, t, o)
        case .web: web(size, t, o)
        case .braid: braid(size, t, o)
        case .ribbon, .ring: ribbon(size, t, o)
        case .morph: morph(size, t, o)
        }
    }

    // MARK: - Orbits (working)

    static func orbits(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.82
        let pt = Proj(yaw: t * 0.12, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let orbitN = Int(o["orbitN"] ?? 12), ghostN = Int(o["ghostN"] ?? 40), particles = Int(o["particles"] ?? 3)
        let ghostR = o["ghostR"] ?? 0.9, ghostA = o["ghostA"] ?? 0.5
        let partR = o["partR"] ?? 1.2, partRDepth = o["partRDepth"] ?? 1.6
        var dots: [Dot] = []
        for orb in 0..<orbitN {
            let ob = Double(orb)
            let h1 = hashD(ob, 1.7), h2 = hashD(ob, 5.2), h3 = hashD(ob, 8.9)
            let ro = R * (0.45 + 0.52 * h1)
            let th = h1 * 2 * .pi
            let phi = acos(2 * h2 - 1)
            let nx = sin(phi) * cos(th), ny = cos(phi), nz = sin(phi) * sin(th)
            var ux = -ny, uy = nx
            let uz = 0.0
            let ul = max(1e-6, (ux * ux + uy * uy).squareRoot())
            ux /= ul; uy /= ul
            let vx = ny * uz - nz * uy, vy = nz * ux - nx * uz, vz = nx * uy - ny * ux
            let speed = (0.25 + 0.55 * h3) * (h3 > 0.5 ? 1 : -1)
            for k in 0..<ghostN {
                let a = (Double(k) / Double(ghostN)) * 2 * .pi
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro, (uy * cos(a) + vy * sin(a)) * ro, (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z, r: ghostR * rs, white: 0.72, a: ghostA * (0.4 + 0.6 * depth)))
            }
            for m in 0..<particles {
                let a = t * speed + (Double(m) / Double(particles)) * 2 * .pi + h2 * 6
                let (px, py, z) = pt((ux * cos(a) + vx * sin(a)) * ro, (uy * cos(a) + vy * sin(a)) * ro, (uz * cos(a) + vz * sin(a)) * ro)
                let depth = (z / ro + 1) / 2
                dots.append(Dot(x: px, y: py, z: z, r: (partR + partRDepth * depth) * rs, white: 0.3 - 0.22 * depth, a: 1))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    // MARK: - Lattice modes (globe, rubik, wave)

    private struct Move { let axis: Int; let lo, hi, ang: Double }

    private static func solveCycle(_ time: Double, _ count: Int, _ slotDur: Double, _ rest: Double) -> (amount: [Double], active: Int) {
        let n = Double(count)
        let cyc = 2 * n * slotDur + rest
        let tc = time.truncatingRemainder(dividingBy: cyc)
        var amount = [Double](repeating: 0, count: count)
        var active = -1
        if tc < 2 * n * slotDur {
            let slot = Int((tc / slotDur).rounded(.down))
            let p = (tc - Double(slot) * slotDur) / slotDur
            let cl = min(1, p / 0.7)
            let ep = 1 - pow(1 - cl, 3)
            if slot < count {
                for i in 0..<slot { amount[i] = 1 }
                amount[slot] = ep
                active = slot
            } else {
                let u = 2 * count - 1 - slot
                for i in 0..<u { amount[i] = 1 }
                amount[u] = 1 - ep
                active = u
            }
        }
        return (amount, active)
    }

    private static func applyMoves(_ p: (Double, Double, Double), _ moves: [Move], _ sc: (amount: [Double], active: Int)) -> (Double, Double, Double, Bool) {
        var (x, y, z) = p
        var inActive = false
        for i in 0..<moves.count {
            if sc.amount[i] <= 0 { continue }
            let mv = moves[i]
            let coord = mv.axis == 0 ? x : mv.axis == 1 ? y : z
            if coord < mv.lo || coord >= mv.hi { continue }
            if i == sc.active { inActive = true }
            let a = mv.ang * sc.amount[i]
            let ca = cos(a), sa = sin(a)
            if mv.axis == 0 {
                let y2 = y * ca - z * sa; z = y * sa + z * ca; y = y2
            } else if mv.axis == 1 {
                let x2 = x * ca + z * sa; z = -x * sa + z * ca; x = x2
            } else {
                let x2 = x * ca - y * sa; y = x * sa + y * ca; x = x2
            }
        }
        return (x, y, z, inActive)
    }

    private static func makeMoves(_ count: Int) -> [Move] {
        (0..<count).map { i in
            let d = Double(i)
            let axis = min(2, Int((hashD(d, 2.3) * 3).rounded(.down)))
            let lo = -1.0 + 0.5 * min(3, (hashD(d, 5.9) * 4).rounded(.down))
            let dir: Double = hashD(d, 7.7) < 0.5 ? 1 : -1
            return Move(axis: axis, lo: lo, hi: lo + 0.5, ang: (dir * .pi) / 2)
        }
    }

    static func globe(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let spin = 0.5
        let cx = size / 2, cy = size / 2
        let radius = (size / 2) * 0.82
        let tilt = 0.4 + 0.06 * sin(t * 0.35)
        let pt = Proj(yaw: t * spin, tilt: tilt, cx: cx, cy: cy, scale: radius)
        let scan = t * (spin + (1.7 - spin) * (o["scanMul"] ?? 1))
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let dimBase = o["dimBase"] ?? 1
        let rBase = o["rBase"] ?? 0.6, rDepth = o["rDepth"] ?? 1.7, rBoost = o["rBoost"] ?? 1
        let inkFar = o["inkFar"] ?? 0.62, inkSpan = o["inkSpan"] ?? 0.54
        let latRings = Int(o["latRings"] ?? 17), lonDensity = o["lonDensity"] ?? 44
        var dots: [Dot] = []
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let lonCount = max(1, Int(jsRound(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon), sinLat, cosLat * sin(lon))
                let depth = (z + 1) / 2
                let d = angleDelta(lon + t * spin, scan)
                let boost = exp(-(d * d) / 0.18) * max(0, z)
                dots.append(Dot(x: px, y: py, z: z, r: (rBase + rDepth * depth + rBoost * boost) * rs,
                                white: inkFar - inkSpan * depth, a: dimBase + (1 - dimBase) * min(1, boost)))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    static func rubik(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.82
        let pt = Proj(yaw: t * 0.55, tilt: 0.35 + 0.1 * sin(t * 0.9), cx: cx, cy: cy, scale: R)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let moveCount = Int(o["moveCount"] ?? 14)
        let moves = makeMoves(moveCount)
        let sc = solveCycle(t, moveCount, 0.42, 1.2)
        let rBase = o["rBase"] ?? 0.6, rDepth = o["rDepth"] ?? 1.7, rActive = o["rActive"] ?? 0.3
        let inkFar = o["inkFar"] ?? 0.62, inkSpan = o["inkSpan"] ?? 0.54
        let latRings = Int(o["latRings"] ?? 15), lonDensity = o["lonDensity"] ?? 40
        var dots: [Dot] = []
        for li in 0...latRings {
            let lat = -Double.pi / 2 + (Double(li) / Double(latRings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let lonCount = max(1, Int(jsRound(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (x, y, z, inActive) = applyMoves((cosLat * cos(lon), sinLat, cosLat * sin(lon)), moves, sc)
                let (px, py, zr) = pt(x, y, z)
                let depth = (zr + 1) / 2
                dots.append(Dot(x: px, y: py, z: zr, r: (rBase + rDepth * depth + (inActive ? rActive : 0)) * rs,
                                white: inkFar - inkSpan * depth - (inActive ? 0.14 : 0), a: 1))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    static func wave(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.874
        let pt = Proj(yaw: t * 0.18, tilt: 0.38, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let rBase = o["rBase"] ?? 0.6, rDepth = o["rDepth"] ?? 1.7
        let rings = Int(o["rings"] ?? 15), lonDensity = o["lonDensity"] ?? 40
        var dots: [Dot] = []
        for ri in 0...rings {
            let r = Double(ri)
            let lat = -Double.pi / 2 + (r / Double(rings)) * .pi
            let cosLat = cos(lat), sinLat = sin(lat)
            let w = 0.62 * sin(t * 2.1 - r * 0.52) + 0.38 * sin(t * 1.27 + r * 0.83)
            let rr = R * (0.88 + 0.105 * w)
            let lonCount = max(1, Int(jsRound(abs(cosLat) * lonDensity)))
            for lj in 0..<lonCount {
                let lon = (Double(lj) / Double(lonCount)) * 2 * .pi
                let (px, py, z) = pt(cosLat * cos(lon) * rr, sinLat * rr, cosLat * sin(lon) * rr)
                let depth = (z / R + 1) / 2
                let crest = max(0, w)
                dots.append(Dot(x: px, y: py, z: z, r: (rBase + rDepth * depth) * (1 + 0.4 * crest) * rs,
                                white: 0.66 - 0.56 * depth - 0.1 * crest, a: 1))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    // MARK: - Web (connecting)

    static func web(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.8 * (o["spread"] ?? 1)
        let pt = Proj(yaw: t * 0.12, tilt: 0.32, cx: cx, cy: cy, scale: R)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let nodeN = Int(o["nodeN"] ?? 30), thr = o["thr"] ?? 0.72
        let nodeR = o["nodeR"] ?? 1.4, nodeRDepth = o["nodeRDepth"] ?? 1.8
        let lineW = o["lineW"] ?? 0.8

        var nodes: [(Double, Double, Double)] = []
        for i in 0..<nodeN {
            let d = fibDir(i, nodeN)
            let fi = Double(i)
            let x = d.0 + 0.3 * (vnoise(fi * 0.31 + 9, t * 0.24) - 0.5) * 2
            let y = d.1 + 0.3 * (vnoise(fi * 0.53 + 27, t * 0.21) - 0.5) * 2
            let z = d.2 + 0.3 * (vnoise(fi * 0.77 + 55, t * 0.27) - 0.5) * 2
            let l = (x * x + y * y + z * z).squareRoot()
            nodes.append((x / l, y / l, z / l))
        }

        var lines: [Line] = []
        var dots: [Dot] = []
        for i in 0..<nodeN {
            for j in (i + 1)..<max(i + 1, nodeN) {
                let dx = nodes[i].0 - nodes[j].0, dy = nodes[i].1 - nodes[j].1, dz = nodes[i].2 - nodes[j].2
                let dist = (dx * dx + dy * dy + dz * dz).squareRoot()
                if dist >= thr { continue }
                let (x1, y1, z1) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
                let (x2, y2, z2) = pt(nodes[j].0, nodes[j].1, nodes[j].2)
                let depth = ((z1 + z2) / 2 + 1) / 2
                lines.append(Line(x1: x1, y1: y1, x2: x2, y2: y2, white: 0.42,
                                  a: (1 - dist / thr) * (0.3 + 0.55 * depth), w: max(0.6, lineW * rs)))
            }
        }
        for i in 0..<nodeN {
            let (px, py, z) = pt(nodes[i].0, nodes[i].1, nodes[i].2)
            let depth = (z + 1) / 2
            let pulse = 1 + 0.25 * sin(t * 1.4 + Double(i) * 2.7)
            dots.append(Dot(x: px, y: py, z: z, r: (nodeR + nodeRDepth * depth) * pulse * rs, white: 0.55 - 0.45 * depth, a: 1))
        }
        let signals = Int(o["signals"] ?? 5)
        for s in 0..<signals {
            let sd = Double(s)
            let seg = (t * 0.55 + sd * 7.31).rounded(.down)
            let a = Int((hashD(seg, sd * 3.1 + 1.7) * Double(nodeN)).rounded(.down))
            let b = Int((hashD(seg, sd * 5.7 + 4.2) * Double(nodeN)).rounded(.down))
            if a == b { continue }
            let f = frac(t * 0.55 + sd * 7.31)
            let x = lerp(nodes[a].0, nodes[b].0, f), y = lerp(nodes[a].1, nodes[b].1, f), z = lerp(nodes[a].2, nodes[b].2, f)
            let l = max(1e-6, (x * x + y * y + z * z).squareRoot())
            let (px, py, zr) = pt(x / l, y / l, z / l)
            let depth = (zr + 1) / 2
            dots.append(Dot(x: px, y: py, z: zr, r: (nodeR * 1.5 + nodeRDepth * depth) * rs, white: 0.05, a: 0.5 + 0.5 * depth))
        }
        return finalize(dots, lines, rMin: o["rMin"])
    }

    // MARK: - Braid (weaving)

    static func braid(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.76
        let pt = Proj(yaw: t * 0.4, tilt: 0.3, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        var dots: [Dot] = []
        let ghostN = Int(o["ghostN"] ?? 150)
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(Dot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
        }
        let strandN = Int(o["strandN"] ?? 52), turns = o["turns"] ?? 3
        let rBase = o["rBase"] ?? 1.2, rDepth = o["rDepth"] ?? 1.8
        for s in 0..<3 {
            let phase = (Double(s) / 3) * 2 * .pi
            for i in 0..<strandN {
                let u = (frac(Double(i) / Double(strandN) + t * 0.045) * 2 - 1) * 0.96
                let surf = max(0, 1 - u * u).squareRoot()
                let endFade = min(1, (1 - abs(u)) / 0.1)
                let a = u * .pi * turns + phase
                let weave = 1 + 0.075 * sin(u * .pi * turns * 2 + phase * 2 + t * 0.8)
                let rr = surf * R * weave
                let (px, py, zr) = pt(cos(a) * rr, u * R * weave, sin(a) * rr)
                let depth = (zr / R + 1) / 2
                dots.append(Dot(x: px, y: py, z: zr, r: (rBase + rDepth * depth) * rs,
                                white: 0.55 - 0.45 * depth, a: endFade * (0.45 + 0.55 * depth)))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    // MARK: - Ribbon (composing) and ring (breathing)

    static func ribbon(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let cx = size / 2, cy = size / 2
        let R = (size / 2) * 0.78
        let spin = o["spin"] ?? 1
        let camTilt = 0.3
        let pt = Proj(yaw: t * 0.1 * spin, tilt: camTilt, cx: cx, cy: cy, scale: 1)
        let rs = radiusScale(size, o["rsPow"] ?? 0.6)
        let faceOn = (o["faceOn"] ?? 0) != 0
        var dots: [Dot] = []
        let ghostN = Int(o["ghostN"] ?? 150)
        for i in 0..<ghostN {
            let d = fibDir(i, ghostN)
            let (px, py, z) = pt(d.0 * R, d.1 * R, d.2 * R)
            let depth = (z / R + 1) / 2
            dots.append(Dot(x: px, y: py, z: z, r: 0.8 * rs, white: 0.78, a: 0.1 + 0.22 * depth))
        }
        let ya = t * 0.24 * spin
        let ta = faceOn ? -camTilt : 0.55 + 0.3 * sin(t * 0.18) * spin
        let ux = cos(ya), uy = 0.0, uz = sin(ya)
        let vx = -uz * sin(ta), vy = cos(ta), vz = ux * sin(ta)
        let nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
        let wobMul = o["wobMul"] ?? 1
        let wobAmp = 0.23 * wobMul
        let baseR = faceOn ? R / (1 + 0.85 * wobAmp) : R
        let segs = Int(o["segs"] ?? 88)
        let lanes = max(1, Int(jsRound((o["lanes"] ?? 5) * (o["bandMul"] ?? 1))))
        let rBase = o["rBase"] ?? 1.1, rDepth = o["rDepth"] ?? 1.7
        for w in 0..<lanes {
            let wd = Double(w), mid = Double(lanes - 1) / 2
            let laneOff = (wd - mid) * 0.075
            let edge = abs(wd - mid) / max(1, mid)
            for k in 0..<segs {
                let a = (Double(k) / Double(segs)) * 2 * .pi
                let wob = (0.16 * sin(a * 3 - t * 1.7 + wd * 0.22) + 0.07 * sin(a * 5 + t * 1.1)) * wobMul
                let radial = faceOn ? 1 + wob : 1
                let off = faceOn ? laneOff : laneOff + wob
                let x = ux * cos(a) + vx * sin(a) + nx * off
                let y = uy * cos(a) + vy * sin(a) + ny * off
                let z = uz * cos(a) + vz * sin(a) + nz * off
                let l = (x * x + y * y + z * z).squareRoot()
                let rr = baseR * radial
                let (px, py, zr) = pt((x / l) * rr, (y / l) * rr, (z / l) * rr)
                let depth = (zr / R + 1) / 2
                dots.append(Dot(x: px, y: py, z: zr, r: (rBase + rDepth * depth) * (1 - 0.25 * edge) * rs,
                                white: 0.52 - 0.44 * depth + 0.18 * edge, a: 0.4 + 0.6 * depth))
            }
        }
        return finalize(dots, [], rMin: o["rMin"])
    }

    // MARK: - Morph (shaping)

    private typealias Outline = (Double) -> (Double, Double)

    private static func polyPath(_ verts: [(Double, Double)]) -> Outline {
        let V = verts.count
        var L: [Double] = []
        var total = 0.0
        for i in 0..<V {
            let a = verts[i], b = verts[(i + 1) % V]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            L.append(l); total += l
        }
        return { f in
            var target = f * total
            var i = 0
            while target > L[i] && i < V - 1 { target -= L[i]; i += 1 }
            let a = verts[i], b = verts[(i + 1) % V]
            let ff = L[i] != 0 ? min(1, target / L[i]) : 0
            return (a.0 + (b.0 - a.0) * ff, a.1 + (b.1 - a.1) * ff)
        }
    }

    private static let cycle: [Outline] = [
        { f in let a = -Double.pi / 2 + f * 2 * .pi; return (cos(a) * 0.24, sin(a) * 0.24) },
        polyPath([(0.0, -0.26), (0.24, 0.16), (-0.24, 0.16)]),
        polyPath([(0, -0.2), (0.2, -0.2), (0.2, 0.2), (-0.2, 0.2), (-0.2, -0.2)]),
    ]

    static let morphHold = 1.4, morphMorph = 0.9

    static func morph(_ size: Double, _ t: Double, _ o: Opts) -> Frame {
        let seg = morphHold + morphMorph
        let K = cycle.count
        let tc = t.truncatingRemainder(dividingBy: seg * Double(K))
        let k = Int((tc / seg).rounded(.down))
        let local = tc - Double(k) * seg
        let x0 = (local - morphHold) / morphMorph
        let m = local > morphHold ? x0 * x0 * (3 - 2 * x0) : 0
        let sprd = o["spread"] ?? 1
        let pA = cycle[k], pB = cycle[(k + 1) % K]
        let M = 160
        var pts: [(Double, Double)] = []
        pts.reserveCapacity(M)
        for i in 0..<M {
            let f = Double(i) / Double(M)
            let a = pA(f), b = pB(f)
            pts.append(((a.0 + (b.0 - a.0) * m) * sprd, (a.1 + (b.1 - a.1) * m) * sprd))
        }
        var L: [Double] = []
        var total = 0.0
        for i in 0..<M {
            let a = pts[i], b = pts[(i + 1) % M]
            let l = hypot(b.0 - a.0, b.1 - a.1)
            L.append(l); total += l
        }
        let n = Int(max(6, jsRound(34 * (o["iconD"] ?? 1))))
        let re = (o["rDot"] ?? 0.021) * 1.35 * sprd
        let pulse = 1 + 0.02 * sin(local * 3.1)
        var dots: [Dot] = []
        let c2 = size / 2
        var s = 0
        var acc = 0.0
        for k2 in 0..<n {
            let target = (Double(k2) / Double(n)) * total
            while acc + L[s] < target && s < M - 1 { acc += L[s]; s += 1 }
            let a = pts[s], b = pts[(s + 1) % M]
            let f = L[s] != 0 ? min(1, (target - acc) / L[s]) : 0
            let x = (a.0 + (b.0 - a.0) * f) * pulse
            let y = (a.1 + (b.1 - a.1) * f) * pulse
            dots.append(Dot(x: c2 + x * size, y: c2 + y * size, z: 0, r: max(0.35, re * size), white: 0.1, a: 1))
        }
        return finalize(dots, [], rMin: o["rMin"])
    }
}
