import CoreGraphics
import Foundation

/// A whiteboard Claude drew: a few boxes and arrows that build up step by step, read from the JSON inside a
/// <board> tag (the format is taught in `Prompts.boardRule`). Keys are short to keep the answer cheap:
/// `{"n":[{"id","t","sub","c","r","key","shape"}],"e":[{"f","to","l","d"}],"s":[{"c","n":[ids]}]}`.
/// Longer names (title, subtitle, column, row, from, label, dashed, caption, ids) are read too.
struct BoardSpec: Equatable {
    enum Shape: String { case box, circle, note }

    struct Node: Equatable, Identifiable {
        var id: String
        var title: String
        var subtitle: String?
        var shape: Shape = .box
        var column: Int
        var row: Int
        var key: Bool = false
    }

    struct Edge: Equatable {
        var from: String
        var to: String
        var label: String?
        var dashed: Bool = false
    }

    struct Step: Equatable {
        var caption: String
        var ids: [String]
    }

    var nodes: [Node]
    var edges: [Edge]
    var steps: [Step]

    // MARK: Limits (plan B3b)

    static let maxNodes = 8
    static let maxSteps = 5
    static let maxTitleWords = 4
    static let maxSubtitleWords = 6
    static let maxNewPerStep = 3
    /// More columns than this can't fit readable cards in a chat answer.
    static let maxColumns = 3

    // MARK: Reading

    /// Reads and checks the JSON. Nil when it isn't JSON, misses its parts, or breaks a rule: the answer then shows
    /// as text, never as a broken board.
    static func parse(_ source: String) -> BoardSpec? {
        guard let spec = decode(source), spec.problems.isEmpty else { return nil }
        return spec
    }

    /// Tolerant reading only (no rules checked): wrong types are skipped, numbers may come as strings.
    static func decode(_ source: String) -> BoardSpec? {
        guard let data = source.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func list(_ keys: [String]) -> [[String: Any]] {
            for k in keys { if let a = root[k] as? [Any] { return a.compactMap { $0 as? [String: Any] } } }
            return []
        }
        func string(_ d: [String: Any], _ keys: [String]) -> String? {
            for k in keys {
                if let s = d[k] as? String {
                    let t = Highlights.strip(s).trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty ? nil : t
                }
                if let n = d[k] as? NSNumber { return n.stringValue }
            }
            return nil
        }
        func int(_ d: [String: Any], _ keys: [String]) -> Int? {
            for k in keys {
                if let n = d[k] as? NSNumber { return Int(n.doubleValue.rounded()) }
                if let s = d[k] as? String, let v = Double(s) { return Int(v.rounded()) }
            }
            return nil
        }
        func bool(_ d: [String: Any], _ keys: [String]) -> Bool {
            for k in keys {
                if let n = d[k] as? NSNumber { return n.boolValue }
                if let s = d[k] as? String { return ["true", "yes", "1"].contains(s.lowercased()) }
            }
            return false
        }

        var nodes: [Node] = []
        for (i, d) in list(["n", "nodes"]).enumerated() {
            guard let id = string(d, ["id", "i"]), let title = string(d, ["t", "title", "label"]) else { continue }
            nodes.append(Node(id: id, title: title, subtitle: string(d, ["sub", "subtitle", "s"]),
                              shape: string(d, ["shape"]).flatMap { Shape(rawValue: $0.lowercased()) } ?? .box,
                              column: int(d, ["c", "col", "column", "x"]) ?? 0,
                              row: int(d, ["r", "row", "y"]) ?? i,
                              key: bool(d, ["key", "k"])))
        }
        let edges: [Edge] = list(["e", "edges"]).compactMap { d in
            guard let from = string(d, ["f", "from"]), let to = string(d, ["to", "t"]) else { return nil }
            return Edge(from: from, to: to, label: string(d, ["l", "label"]), dashed: bool(d, ["d", "dashed"]))
        }
        let steps: [Step] = list(["s", "steps"]).compactMap { d in
            let caption = string(d, ["c", "caption", "text"]) ?? ""
            var ids: [String] = []
            for k in ["n", "ids", "nodes"] {
                if let a = d[k] as? [Any] { ids = a.compactMap { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue }; break }
            }
            return Step(caption: caption, ids: ids)
        }
        guard !nodes.isEmpty, !steps.isEmpty else { return nil }
        return BoardSpec(nodes: nodes, edges: edges, steps: steps)
    }

    // MARK: Checking

    private static func words(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// Every rule this board breaks, in plain words. Empty means it can be drawn.
    var problems: [String] {
        var out: [String] = []
        let ids = nodes.map(\.id)
        let known = Set(ids)
        if nodes.count > Self.maxNodes { out.append("more than \(Self.maxNodes) nodes") }
        if steps.count > Self.maxSteps { out.append("more than \(Self.maxSteps) steps") }
        if known.count != ids.count { out.append("two nodes share an id") }
        for n in nodes {
            if Self.words(n.title) > Self.maxTitleWords { out.append("title too long: \(n.title)") }
            if let s = n.subtitle, Self.words(s) > Self.maxSubtitleWords { out.append("subtitle too long: \(s)") }
            if n.column < 0 || n.row < 0 { out.append("negative grid place: \(n.id)") }
        }
        var cells = Set<String>()
        for n in nodes where !cells.insert("\(n.column),\(n.row)").inserted { out.append("two nodes in one place: \(n.id)") }
        if Set(nodes.map(\.column)).count > Self.maxColumns { out.append("more than \(Self.maxColumns) columns") }
        for e in edges {
            if !known.contains(e.from) || !known.contains(e.to) { out.append("arrow to a missing node: \(e.from)→\(e.to)") }
            if e.from == e.to { out.append("arrow from a node to itself: \(e.from)") }
        }
        var seen = Set<String>()
        for (i, s) in steps.enumerated() {
            if s.caption.isEmpty { out.append("step \(i + 1) has no caption") }
            for id in s.ids where !known.contains(id) { out.append("step \(i + 1) names a missing node: \(id)") }
            let fresh = Set(s.ids).subtracting(seen).intersection(known)
            if fresh.count > Self.maxNewPerStep { out.append("step \(i + 1) adds more than \(Self.maxNewPerStep) nodes") }
            seen.formUnion(fresh)
        }
        for id in ids where !seen.contains(id) { out.append("node in no step: \(id)") }
        if nodes.count > 1 {
            let linked = Set(edges.flatMap { [$0.from, $0.to] })
            for id in ids where !linked.contains(id) { out.append("node with no arrow: \(id)") }
        }
        // Only a board that is otherwise sound is laid out: no arrow may cut through a card, at a narrow or a wide width.
        if out.isEmpty {
            for width: CGFloat in [300, 600] { out += BoardLayout(self, .init(width: width)).crossings }
        }
        return out
    }

    // MARK: Steps

    /// The step (0-based) in which each node first shows.
    var firstStep: [String: Int] {
        var out: [String: Int] = [:]
        for (i, s) in steps.enumerated() { for id in s.ids where out[id] == nil { out[id] = i } }
        return out
    }

    /// An arrow shows once both its ends are on the board.
    func firstStep(of edge: Edge) -> Int {
        let f = firstStep
        return max(f[edge.from] ?? 0, f[edge.to] ?? 0)
    }

    /// Nodes at full strength in `step`: the ones that step names. The last step shows everything at full strength.
    func inFocus(at step: Int) -> Set<String> {
        guard steps.indices.contains(step) else { return [] }
        if step == steps.count - 1 { return Set(nodes.map(\.id)) }
        return Set(steps[step].ids)
    }

    /// What to say when the board can't be drawn: the captions, which carry the explanation, as a numbered list.
    /// Empty when nothing usable is there.
    static func fallbackText(_ source: String) -> String {
        guard let spec = decode(source) else { return "" }
        let captions = spec.steps.map(\.caption).filter { !$0.isEmpty }
        guard !captions.isEmpty else { return "" }
        return captions.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
    }

    private static let tagPattern = try! NSRegularExpression(pattern: #"<board\b[^>]*>(.*?)(?:</board\s*>|$)"#,
                                                             options: [.dotMatchesLineSeparators, .caseInsensitive])

    /// A finished answer with a <board> that can't be drawn (bad JSON, a broken rule, or never closed). A local model's
    /// answer like this is asked again of Claude, once (plan B4).
    static func hasBrokenBoard(_ answer: String) -> Bool {
        let ns = answer as NSString
        return tagPattern.matches(in: answer, range: NSRange(location: 0, length: ns.length)).contains { m in
            let whole = ns.substring(with: m.range)
            guard whole.range(of: #"</board\s*>$"#, options: [.regularExpression, .caseInsensitive]) != nil else { return true }
            return parse(ns.substring(with: m.range(at: 1))) == nil
        }
    }

    /// The board as words, for prompts, titles and search.
    var plainText: String { steps.map(\.caption).filter { !$0.isEmpty }.joined(separator: " ") }
}

// MARK: - Layout

/// Where every node and arrow goes, from the grid places alone (no free coordinates). Pure, so the tests and the
/// view share it. Columns and rows are compacted (only the ones used count), the grid is centred, and the flow
/// runs top to bottom.
struct BoardLayout {
    struct Metrics {
        var width: CGFloat
        var maxNodeWidth: CGFloat = 168
        var columnGap: CGFloat = 14
        var rowGap: CGFloat = 30
        var titleOnlyHeight: CGFloat = 38
        var withSubtitleHeight: CGFloat = 52
        /// Narrow cards (three to a row in a chat) let the title and subtitle wrap to two lines each.
        var narrowWidth: CGFloat = 140
        var narrowTitleOnlyHeight: CGFloat = 50
        var narrowWithSubtitleHeight: CGFloat = 78
        var inset: CGFloat = 2
    }

    struct Arrow: Equatable {
        var from: String
        var to: String
        var start: CGPoint
        var end: CGPoint
        var control1: CGPoint
        var control2: CGPoint
        var labelAt: CGPoint
    }

    let frames: [String: CGRect]
    let arrows: [Arrow]
    let size: CGSize
    let nodeSize: CGSize

    init(_ spec: BoardSpec, _ m: Metrics) {
        let columns = Array(Set(spec.nodes.map(\.column))).sorted()
        let rows = Array(Set(spec.nodes.map(\.row))).sorted()
        let colIndex = Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($1, $0) })
        let rowIndex = Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1, $0) })
        let n = CGFloat(max(columns.count, 1))
        let usable = max(m.width - m.inset * 2, 60)
        // Columns are spread evenly, so a lone card in the middle column sits centred over a pair at the sides. The
        // closest two cards that share a row (in column steps) set how wide every card can be without touching.
        var closest = n - 1
        for row in rows {
            let used = spec.nodes.filter { $0.row == row }.compactMap { colIndex[$0.column] }.sorted()
            for (a, b) in zip(used, used.dropFirst()) { closest = min(closest, CGFloat(b - a)) }
        }
        closest = max(closest, 1)
        let w: CGFloat
        let pitch: CGFloat // centre to centre, one column step
        if n == 1 {
            w = min(m.maxNodeWidth, usable).rounded(.down)
            pitch = 0
        } else {
            w = min(m.maxNodeWidth, (closest * usable - (n - 1) * m.columnGap) / (closest + n - 1)).rounded(.down)
            pitch = (w + m.columnGap) / closest
        }
        let subtitles = spec.nodes.contains { $0.subtitle != nil }
        let h = w < m.narrowWidth ? (subtitles ? m.narrowWithSubtitleHeight : m.narrowTitleOnlyHeight)
            : (subtitles ? m.withSubtitleHeight : m.titleOnlyHeight)
        let gridWidth = w + (n - 1) * pitch
        let left = ((m.width - gridWidth) / 2).rounded()
        var frames: [String: CGRect] = [:]
        for node in spec.nodes {
            let c = CGFloat(colIndex[node.column] ?? 0), r = CGFloat(rowIndex[node.row] ?? 0)
            frames[node.id] = CGRect(x: (left + c * pitch).rounded(), y: m.inset + r * (h + m.rowGap), width: w, height: h)
        }
        let rowsCount = CGFloat(max(rows.count, 1))
        self.frames = frames
        self.nodeSize = CGSize(width: w, height: h)
        self.size = CGSize(width: m.width, height: m.inset * 2 + rowsCount * h + (rowsCount - 1) * m.rowGap)

        // Several arrows leaving (or reaching) one card get their own spots along its edge, ordered by where the other
        // end is, so they fan out instead of sharing one point.
        func port(_ id: String, _ others: [String], _ other: String) -> CGFloat {
            guard let f = frames[id], others.count > 1, let i = others.sorted(by: { (frames[$0]?.midX ?? 0) < (frames[$1]?.midX ?? 0) })
                .firstIndex(of: other) else { return 0 }
            let spacing = min(f.width / CGFloat(others.count + 1), 26)
            return (CGFloat(i) - CGFloat(others.count - 1) / 2) * spacing
        }
        var arrows: [Arrow] = []
        for e in spec.edges {
            guard let a = frames[e.from], let b = frames[e.to] else { continue }
            let outs = spec.edges.filter { $0.from == e.from && frames[$0.to].map { abs($0.minY - a.minY) >= 1 } == true }.map(\.to)
            let ins = spec.edges.filter { $0.to == e.to && frames[$0.from].map { abs($0.minY - b.minY) >= 1 } == true }.map(\.from)
            arrows.append(Self.route(from: a, to: b, among: Array(frames.values), gap: m.rowGap, ids: (e.from, e.to),
                                     shift: (port(e.from, outs, e.to), port(e.to, ins, e.from)), lane: m.columnGap, width: m.width))
        }
        self.arrows = arrows
    }

    /// A soft curve from one card to the next. Down (the usual case): bottom edge to top edge. Same row: side to side.
    /// When a straight path would cross another card (a jump over a row), it bows out past the cards' side.
    static func route(from a: CGRect, to b: CGRect, among all: [CGRect], gap: CGFloat, ids: (String, String),
                      shift: (CGFloat, CGFloat) = (0, 0), lane: CGFloat = 14, width: CGFloat = .infinity) -> Arrow {
        let pad: CGFloat = 3
        if abs(a.minY - b.minY) < 1 {
            // Same row: side to side.
            let leftToRight = b.midX > a.midX
            let s = CGPoint(x: leftToRight ? a.maxX + pad : a.minX - pad, y: a.midY)
            let t = CGPoint(x: leftToRight ? b.minX - pad : b.maxX + pad, y: b.midY)
            let dx = (t.x - s.x) / 2
            return Arrow(from: ids.0, to: ids.1, start: s, end: t, control1: CGPoint(x: s.x + dx, y: s.y),
                         control2: CGPoint(x: t.x - dx, y: t.y), labelAt: CGPoint(x: (s.x + t.x) / 2, y: s.y - 9))
        }
        let down = b.minY > a.minY
        let s = CGPoint(x: a.midX + shift.0, y: down ? a.maxY + pad : a.minY - pad)
        let t = CGPoint(x: b.midX + shift.1, y: down ? b.minY - pad : b.maxY + pad)
        let between = all.filter { r in
            r != a && r != b && r.maxY > min(a.maxY, b.maxY) && r.minY < max(a.minY, b.minY)
                && r.maxX > min(s.x, t.x) - 4 && r.minX < max(s.x, t.x) + 4
        }
        if between.isEmpty {
            let dy = (t.y - s.y) * 0.5
            return Arrow(from: ids.0, to: ids.1, start: s, end: t, control1: CGPoint(x: s.x, y: s.y + dy),
                         control2: CGPoint(x: t.x, y: t.y - dy), labelAt: CGPoint(x: (s.x + t.x) / 2, y: (s.y + t.y) / 2))
        }
        // A jump down one column over a card in the way: leave and arrive on one side and run down the gutter beside
        // the column (right if it is inside the board, else left). Other jumps can't be drawn cleanly: `crossings` finds
        // them and the board falls back to text.
        let right = max(a.maxX, b.maxX) + lane / 2 <= width - 1
        let side: CGFloat = right ? 1 : -1
        let s2 = CGPoint(x: right ? a.maxX + pad : a.minX - pad, y: a.midY)
        let t2 = CGPoint(x: right ? b.maxX + pad : b.minX - pad, y: b.midY)
        let reach = (lane / 2 - pad) / 0.75 // a cubic with both handles at x reaches 3/4 of the way there
        let cx = (right ? max(s2.x, t2.x) : min(s2.x, t2.x)) + side * reach
        return Arrow(from: ids.0, to: ids.1, start: s2, end: t2, control1: CGPoint(x: cx, y: s2.y),
                     control2: CGPoint(x: cx, y: t2.y), labelAt: CGPoint(x: cx, y: (s2.y + t2.y) / 2))
    }

    /// A point on an arrow's curve, `t` from 0 to 1.
    static func point(on a: Arrow, at t: CGFloat) -> CGPoint {
        let u = 1 - t
        return CGPoint(x: u * u * u * a.start.x + 3 * u * u * t * a.control1.x + 3 * u * t * t * a.control2.x + t * t * t * a.end.x,
                       y: u * u * u * a.start.y + 3 * u * u * t * a.control1.y + 3 * u * t * t * a.control2.y + t * t * t * a.end.y)
    }

    /// Every arrow that runs through a card or off the board's sides. A board with any is not drawn.
    var crossings: [String] {
        var out: [String] = []
        for a in arrows {
            for k in 0...40 {
                let p = Self.point(on: a, at: CGFloat(k) / 40)
                if p.x < 0 || p.x > size.width { out.append("\(a.from)→\(a.to) leaves the board"); break }
                if let hit = frames.first(where: { $0.value.insetBy(dx: 1, dy: 1).contains(p) }) {
                    out.append("\(a.from)→\(a.to) crosses \(hit.key)")
                    break
                }
            }
        }
        return out
    }

    /// The height down to the lowest card in `ids`: the board grows downward one step at a time, so nothing waits as
    /// empty space and the cards already shown never move.
    func height(showing ids: Set<String>, inset: CGFloat = Metrics(width: 0).inset) -> CGFloat {
        let bottom = frames.filter { ids.contains($0.key) }.map(\.value.maxY).max()
        return bottom.map { $0 + inset } ?? size.height
    }

    /// True when no two cards overlap (checked by the tests for every board the app draws).
    var hasNoOverlap: Bool {
        let all = Array(frames.values)
        for i in all.indices { for j in all.indices where j > i { if all[i].intersects(all[j]) { return false } } }
        return true
    }
}

extension BoardSpec {
    /// The price ceiling board (6 nodes, 4 steps, key node "Shortage"): the quality target, used by the tests and pictures.
    static let priceCeilingSample = #"""
    {"n":[{"id":"cap","t":"Price ceiling","sub":"Legal maximum below P*","c":1,"r":0},
    {"id":"qd","t":"Demand ↑","sub":"Cheaper, so buyers want more","c":0,"r":1},
    {"id":"qs","t":"Supply ↓","sub":"Less profit, so firms make less","c":2,"r":1},
    {"id":"gap","t":"Shortage","sub":"Qd is greater than Qs","c":1,"r":2,"key":1},
    {"id":"queue","t":"Queues and waiting","sub":"Time replaces price","c":0,"r":3},
    {"id":"black","t":"Black markets","sub":"Sold above the ceiling","c":2,"r":3}],
    "e":[{"f":"cap","to":"qd"},{"f":"cap","to":"qs"},{"f":"qd","to":"gap"},{"f":"qs","to":"gap"},
    {"f":"gap","to":"queue"},{"f":"gap","to":"black","d":1}],
    "s":[{"c":"The government sets a maximum price below the market price P*.","n":["cap"]},
    {"c":"At the lower price, buyers want more and sellers offer less.","n":["qd","qs"]},
    {"c":"Quantity demanded is now greater than quantity supplied: a shortage.","n":["gap"]},
    {"c":"The goods are rationed by queues, and some are sold illegally above the ceiling.","n":["queue","black"]}]}
    """#
}
