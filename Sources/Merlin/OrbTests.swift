import Foundation

/// Checks for the thinking-orbs port. `run` is part of `--unittest` (a small built-in sample of the golden file);
/// `golden` is `--orbtest [path]`, every dot of all 72 golden frames (third_party/thinking-orbs/orbs-golden.json).
enum OrbTests {
    /// (state, dots, lines, first dot, last dot) for the 20-point preset at t = 1.7, copied from orbs-golden.json.
    private static let sample: [(Orb.State, Int, Int, [Double], [Double])] = [
        (.working, 39, 0, [10.285845, 9.91107, -7.548047, 0.425401, 0.72, 0.200118], [9.714155, 10.08893, 7.548047, 0.425401, 0.72, 0.499882]),
        (.searching, 54, 0, [11.391322, 10.794572, -0.980725, 0.3, 0.614796, 0.45], [8.608678, 9.205428, 0.980725, 0.976657, 0.085204, 0.979487]),
        (.solving, 30, 0, [10.144267, 10.604283, -0.997126, 0.3, 0.619224, 1], [10.864201, 7.2722, 0.93714, 0.840657, 0.096972, 1]),
        (.listening, 42, 0, [11.601351, 9.551738, -7.619978, 0.3, 0.612337, 1], [8.386569, 10.451643, 7.677457, 0.742565, 0.115848, 1]),
        (.connecting, 9, 0, [9.463514, 5.457987, -0.820464, 0.584018, 0.509604, 1], [6.063945, 7.72457, 0.822818, 0.697856, 0.139866, 1]),
        (.weaving, 35, 0, [8.227592, 9.589242, -7.379014, 0.3, 0.78, 0.103198], [9.638712, 8.62566, 7.28806, 0.793642, 0.109235, 0.988713]),
        (.composing, 208, 0, [10, 12.155109, -7.496366, 0.3, 0.691436, 0.411678], [12.198967, 7.933103, 7.19253, 0.433285, 0.277134, 0.976636]),
        (.breathing, 120, 0, [3.87639, 14.449063, -1.986914, 0.415313, 0.536041, 0.62358], [12.35304, 17.241913, 1.998832, 0.519375, 0.423623, 0.776878]),
        (.shaping, 18, 0, [10, 3.010296, 0, 0.831194, 0.1, 1], [7.895991, 3.876692, 0, 0.831194, 0.1, 1]),
    ]

    private static func values(_ d: Orb.Dot) -> [Double] { [d.x, d.y, d.z, d.r, d.white, d.a] }
    private static func close(_ a: [Double], _ b: [Double], _ eps: Double = 1e-4) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= eps }
    }

    static func run(_ check: (String, Bool) -> Void) {
        for (state, dots, lines, first, last) in sample {
            let r = Orb.resolve(state, .small)
            let f = Orb.frame(r.mode, size: 20, t: 1.7, opts: r.opts)
            let ok = f.dots.count == dots && f.lines.count == lines
                && f.dots.first.map { close(values($0), first) } == true && f.dots.last.map { close(values($0), last) } == true
            check("orb \(state.rawValue)-20 matches the golden frame at t 1.7", ok)
        }
        check("orb: a search status shows the globe", ThinkingOrb.state(forStatus: "Searching “swift 6.4”") == .searching)
        check("orb: a page read shows the web", ThinkingOrb.state(forStatus: "Reading apple.com") == .connecting)
        check("orb: a video summary shows the ribbon", ThinkingOrb.state(forStatus: "Reading part 2 of 5 on your Mac…") == .composing
              && ThinkingOrb.state(forStatus: "Writing the summary on your Mac…") == .composing)
        check("orb: a video transcript shows the wave", ThinkingOrb.state(forStatus: "Listening · 0:42") == .listening)
        check("orb: plain thinking shows orbits, Local mode the ring",
              ThinkingOrb.state(forStatus: nil) == .working && ThinkingOrb.state(forStatus: nil, local: true) == .breathing
              && ThinkingOrb.state(forStatus: "Working…") == .working)
    }

    /// Full parity run. A missing or unreadable file is a failure, never a silent pass.
    static func golden(path: String) -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cases = json["cases"] as? [[String: Any]], let resolved = json["resolved"] as? [String: [String: Any]] else {
            print("FAIL could not read the golden file at \(path)")
            exit(1)
        }
        let eps = json["tolerance"] as? Double ?? 1e-4
        var failures = 0
        func fail(_ s: String) { print("FAIL " + s); failures += 1 }

        // Presets first: a scaling bug shows here, before any geometry.
        for state in Orb.State.allCases {
            for size in Orb.Size.allCases {
                let key = "\(state.rawValue)-\(size.rawValue)"
                guard let g = resolved[key], let gOpts = g["opts"] as? [String: Double], let gSpeed = g["speed"] as? Double else { fail("\(key): no resolved entry"); continue }
                let r = Orb.resolve(state, size)
                let same = r.mode.rawValue == g["mode"] as? String && abs(r.speed - gSpeed) < 1e-12 && Set(r.opts.keys) == Set(gOpts.keys)
                    && gOpts.allSatisfy { abs((r.opts[$0.key] ?? .nan) - $0.value) < 1e-9 }
                if !same { fail("\(key): resolved opts differ\n  swift \(r.opts.sorted { $0.key < $1.key })\n  web   \(gOpts.sorted { $0.key < $1.key })") }
            }
        }

        var dotsChecked = 0, linesChecked = 0
        for c in cases {
            guard let key = c["key"] as? String, let stateName = c["state"] as? String, let state = Orb.State(rawValue: stateName),
                  let sizeNum = c["size"] as? Int, let size = Orb.Size(rawValue: sizeNum), let t = c["t"] as? Double,
                  let gDots = c["dots"] as? [Double], let gLines = c["lines"] as? [Double] else { fail("bad case \(c["key"] ?? "?")"); continue }
            let r = Orb.resolve(state, size)
            let f = Orb.frame(r.mode, size: Double(sizeNum), t: t, opts: r.opts)
            guard f.dots.count * 6 == gDots.count, f.lines.count * 7 == gLines.count else {
                fail("\(key): \(f.dots.count) dots / \(f.lines.count) lines, golden \(gDots.count / 6) / \(gLines.count / 7)"); continue
            }
            var bad = 0
            // Dots at the same depth (to the golden file's 6 decimals) may swap places: libm differences of one ulp in z
            // reorder exact ties (the face-on ring has many z = 0 dots). Order within such a group can't be seen,
            // so compare each group as a set, sorted by its rounded values.
            func bucket(_ v: [Double]) -> [Double] { v.map { ($0 * 1e4).rounded() } }
            let mine = f.dots.map(values), theirs = (0..<(gDots.count / 6)).map { Array(gDots[($0 * 6)..<($0 * 6 + 6)]) }
            let orderOnly = !zip(mine, theirs).allSatisfy { close($0, $1, eps) }
                && zip(mine.sorted { bucket($0).lexicographicallyPrecedes(bucket($1)) }, theirs.sorted { bucket($0).lexicographicallyPrecedes(bucket($1)) })
                    .allSatisfy { close($0, $1, eps) }
                && zip(mine, theirs).allSatisfy { abs($0[2] - $1[2]) <= eps }
            if orderOnly { print("     \(key): same dots, ties at equal depth in another order") }
            for (i, d) in f.dots.enumerated() where !orderOnly {
                let g = Array(gDots[(i * 6)..<(i * 6 + 6)])
                if !close(values(d), g, eps) {
                    if bad < 3 { print("     \(key) dot \(i): swift \(values(d)) golden \(g)") }
                    bad += 1
                }
            }
            for (i, l) in f.lines.enumerated() {
                let g = Array(gLines[(i * 7)..<(i * 7 + 7)])
                if !close([l.x1, l.y1, l.x2, l.y2, l.white, l.a, l.w], g, eps) {
                    if bad < 3 { print("     \(key) line \(i) differs") }
                    bad += 1
                }
            }
            dotsChecked += f.dots.count; linesChecked += f.lines.count
            if bad > 0 { fail("\(key): \(bad) marks outside \(eps)") } else { print("ok   \(key) (\(f.dots.count) dots, \(f.lines.count) lines)") }
        }
        print(failures == 0 ? "All \(cases.count) golden frames match (\(dotsChecked) dots, \(linesChecked) lines)." : "\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
