import Foundation

/// A small 3D scene Claude composed from primitives, read from the JSON inside a <scene> tag (the format is taught in
/// `Prompts.sceneRule`). Keys are short to keep the answer cheap:
/// `{"p":[{"id","k","s","at":[x,y,z],"c","x","d":[x,y,z],"o":{"a","r","t","tilt"},"spin"}],"cap"}`.
/// Longer names (kind, size, position, colour/color, text, direction, orbit, around, radius, period, caption) are read too.
/// Only grid places (whole or half steps, −6…6) and palette colour names: the app chooses the look.
struct SceneSpec: Equatable {
    enum Kind: String, CaseIterable { case sphere, box, cylinder, cone, torus, arrow, label }

    /// The fixed palette. The app maps each name to a colour; an unknown name is `neutral`.
    enum Colour: String, CaseIterable { case red, orange, yellow, green, blue, purple, white, neutral }

    struct Orbit: Equatable {
        /// The part it circles; nil is the origin.
        var around: String?
        var radius: Double
        /// Seconds for one turn.
        var period: Double
        /// Tilt of the orbit's plane, in degrees about the x axis (0 is flat).
        var tilt: Double = 0
    }

    struct Part: Equatable {
        var id: String
        var kind: Kind
        /// Up to three numbers; what they mean depends on the kind (see `SceneBuilder`).
        var size: [Double]
        var x: Double, y: Double, z: Double
        var colour: Colour
        var text: String?
        /// An arrow's direction (never zero length).
        var direction: [Double] = [0, 1, 0]
        var orbit: Orbit?
        /// Seconds for one turn about the vertical axis.
        var spin: Double?
    }

    var parts: [Part]
    var caption: String?

    // MARK: Limits

    static let maxParts = 12
    static let gridLimit = 6.0
    static let minSize = 0.05, maxSize = 6.0
    static let maxOrbitRadius = 6.0
    /// No turn faster than this many seconds (and never a zero or negative duration for SceneKit).
    static let minPeriod = 1.0, maxPeriod = 120.0
    static let maxTextLength = 24

    // MARK: Reading

    /// Reads, trims and checks the JSON. Nil when it isn't JSON or has no part that can be drawn: the answer then shows
    /// as text, never as a broken scene.
    static func parse(_ source: String) -> SceneSpec? {
        guard let spec = decode(source), !spec.parts.isEmpty else { return nil }
        return spec
    }

    /// Tolerant reading: wrong types are skipped, numbers may come as strings, NaN and infinity are dropped, places
    /// and sizes are clamped, unknown kinds are dropped, unknown colours are neutral, and only the first 12 parts count.
    static func decode(_ source: String) -> SceneSpec? {
        guard let data = source.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func number(_ v: Any?) -> Double? {
            var d: Double?
            if let n = v as? NSNumber, !(n === kCFBooleanTrue || n === kCFBooleanFalse) { d = n.doubleValue }
            if let s = v as? String { d = Double(s.trimmingCharacters(in: .whitespaces)) }
            guard let d, d.isFinite else { return nil }
            return d
        }
        /// Each slot kept (a bad number is nil), so a dropped x never shifts y into its place.
        func slots(_ v: Any?) -> [Double?] {
            if let a = v as? [Any] { return a.map(number) }
            return [number(v)]
        }
        func numbers(_ v: Any?) -> [Double] { slots(v).compactMap { $0 } }
        func first(_ d: [String: Any], _ keys: [String]) -> Any? {
            for k in keys { if let v = d[k] { return v } }
            return nil
        }
        func string(_ d: [String: Any], _ keys: [String]) -> String? {
            switch first(d, keys) {
            case let s as String:
                let t = Highlights.strip(s).trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            case let n as NSNumber: return n.stringValue
            default: return nil
            }
        }
        func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }
        /// A grid place: nearest half step, inside −6…6.
        func place(_ v: Double?) -> Double { clamp(((v ?? 0) * 2).rounded() / 2, -gridLimit, gridLimit) }
        func period(_ v: Double?) -> Double? { v.map { clamp(abs($0), minPeriod, maxPeriod) } }

        let list: [[String: Any]] = {
            for k in ["p", "parts"] { if let a = root[k] as? [Any] { return a.compactMap { $0 as? [String: Any] } } }
            return []
        }()
        var parts: [Part] = []
        var used = Set<String>()
        for (i, d) in list.enumerated() {
            guard parts.count < maxParts else { break } // extra parts are trimmed, not rejected
            guard let kindName = string(d, ["k", "kind", "type", "shape"]),
                  let kind = Kind(rawValue: kindName.lowercased()) ?? alias(kindName) else { continue }
            // "x" is a label's text when it is words; a number there is a place (with "y" and "z").
            var text = (d["x"] as? String).flatMap { _ in string(d, ["x"]) } ?? string(d, ["text", "t", "label"])
            if let t = text, t.count > maxTextLength { text = String(t.prefix(maxTextLength)) }
            if kind == .label && text == nil { continue }
            var id = string(d, ["id", "i"]) ?? "part\(i)"
            if used.contains(id) { id += "-\(i)" }
            used.insert(id)
            let at = first(d, ["at", "pos", "position", "xyz"]).map(slots)
                ?? (["x", "y", "z"].contains { d[$0] != nil && !(d[$0] is String) } ? ["x", "y", "z"].map { number(d[$0]) } : [])
            let size = numbers(first(d, ["s", "size"])).prefix(3).map { clamp(abs($0), minSize, maxSize) }
            var direction = slots(first(d, ["d", "dir", "direction"])).prefix(3).map { clamp($0 ?? 0, -gridLimit, gridLimit) }
            while direction.count < 3 { direction.append(0) }
            if direction.allSatisfy({ abs($0) < 0.001 }) { direction = [0, 1, 0] }
            var orbit: Orbit?
            if let o = first(d, ["o", "orbit"]) as? [String: Any] {
                let r = number(first(o, ["r", "radius"])).map { clamp(abs($0), 0.5, maxOrbitRadius) } ?? 2
                orbit = Orbit(around: string(o, ["a", "around", "of"]), radius: r,
                              period: period(number(first(o, ["t", "period", "p"]))) ?? 6,
                              tilt: clamp(number(first(o, ["tilt", "i"])) ?? 0, -90, 90))
            }
            parts.append(Part(id: id, kind: kind, size: size,
                              x: place(at.first ?? nil), y: place(at.count > 1 ? at[1] : nil), z: place(at.count > 2 ? at[2] : nil),
                              colour: Colour.named(string(d, ["c", "colour", "color"])), text: text,
                              direction: direction, orbit: orbit,
                              spin: period(number(first(d, ["spin", "sp"])))))
        }
        // An orbit around a missing part, itself, or a ring of parts circles the origin instead (SceneKit can't parent a cycle).
        let ids = Set(parts.map(\.id))
        for i in parts.indices {
            guard var o = parts[i].orbit, let target = o.around else { continue }
            if !ids.contains(target) || target == parts[i].id { o.around = nil }
            parts[i].orbit = o
        }
        for i in parts.indices where parts[i].orbit?.around != nil {
            var seen: Set<String> = [parts[i].id]
            var cursor = parts[i].orbit?.around
            while let c = cursor {
                if seen.contains(c) { parts[i].orbit?.around = nil; break }
                seen.insert(c)
                cursor = parts.first { $0.id == c }?.orbit?.around
            }
        }
        let caption = string(root, ["cap", "caption", "c"])
        return SceneSpec(parts: parts, caption: caption)
    }

    private static func alias(_ name: String) -> Kind? {
        switch name.lowercased() {
        case "ball", "atom", "planet", "dot": return .sphere
        case "cube", "block": return .box
        case "rod", "tube", "pipe": return .cylinder
        case "ring", "donut": return .torus
        case "vector", "force": return .arrow
        case "text": return .label
        default: return nil
        }
    }

    // MARK: Words

    /// What to say when the scene can't be drawn: the caption and the labels. Empty when nothing usable is there.
    static func fallbackText(_ source: String) -> String {
        guard let spec = decode(source) else { return "" }
        return spec.plainText
    }

    /// The scene as words, for prompts, titles and search.
    var plainText: String {
        let labels = parts.compactMap { $0.kind == .label ? $0.text : nil }
        var out = caption ?? ""
        if !labels.isEmpty { out += (out.isEmpty ? "" : " ") + "(" + labels.joined(separator: ", ") + ")" }
        return out
    }

    // MARK: Samples (the pictures and the tests)

    /// An atom: a nucleus and three electrons on tilted orbits.
    static let atomSample = #"""
    {"p":[{"id":"n","k":"sphere","s":0.9,"c":"red"},
    {"id":"e1","k":"sphere","s":0.22,"c":"blue","o":{"a":"n","r":2.6,"t":4}},
    {"id":"e2","k":"sphere","s":0.22,"c":"blue","o":{"a":"n","r":2.6,"t":5,"tilt":60}},
    {"id":"e3","k":"sphere","s":0.22,"c":"blue","o":{"a":"n","r":2.6,"t":6,"tilt":-60}},
    {"k":"label","x":"Nucleus","at":[0,1.5,0]}],
    "cap":"Electrons move around a small, dense nucleus."}
    """#

    /// Forces on a block: a box with four arrows and their labels.
    static let forcesSample = #"""
    {"p":[{"id":"b","k":"box","s":[1.6,1,1],"c":"neutral"},
    {"id":"w","k":"arrow","s":1.6,"at":[0,-0.5,0],"d":[0,-1,0],"c":"red"},
    {"id":"r","k":"arrow","s":1.6,"at":[0,0.5,0],"d":[0,1,0],"c":"green"},
    {"id":"p","k":"arrow","s":1.6,"at":[0.8,0,0],"d":[1,0,0],"c":"blue"},
    {"id":"f","k":"arrow","s":1.2,"at":[-0.8,0,0],"d":[-1,0,0],"c":"orange"},
    {"k":"label","x":"Weight","at":[0.5,-2.5,0]},{"k":"label","x":"Normal","at":[0.5,2.5,0]},
    {"k":"label","x":"Push","at":[2.5,0.5,0]},{"k":"label","x":"Friction","at":[-2.5,0.5,0]}],
    "cap":"Four forces act on the block; the push is bigger than friction."}
    """#
}

extension SceneSpec.Colour {
    static func named(_ name: String?) -> Self {
        guard let n = name?.lowercased() else { return .neutral }
        if let c = Self(rawValue: n) { return c }
        switch n {
        case "grey", "gray", "silver": return .neutral
        case "pink", "violet", "magenta": return .purple
        case "gold": return .yellow
        case "cyan", "teal", "navy": return .blue
        case "brown": return .orange
        default: return .neutral
        }
    }
}
