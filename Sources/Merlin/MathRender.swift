import AppKit
import SwiftMath
import SwiftUI

/// Real equations in answers: finds `$…$`, `\(…\)` (inline) and `$$…$$`, `\[…\]` (display) in the model's text and typesets
/// them with the vendored SwiftMath (Latin Modern Math). Anything it can't typeset stays as readable text (see MathPretty).
enum MathRender {
    enum Piece: Equatable {
        case text(String)
        case inline(String)
        case block(String)
        /// Maths found in plain text (the model forgot the `$`): typeset it, or show `raw` if that fails.
        case auto(String, raw: String)
    }

    // `$$…$$` or `\[…\]`, across lines.
    private static let displayRegex = try! NSRegularExpression(pattern: #"\$\$(.+?)\$\$|\\\[(.+?)\\\]"#, options: [.dotMatchesLineSeparators])
    // `\(…\)`, or `$…$` that isn't money: no space inside the dollars, not followed by a digit, not after a word character.
    private static let inlineRegex = try! NSRegularExpression(pattern: #"\\\((.+?)\\\)|(?<![\\$\w])\$(?=[^\s$])([^$\n]+?)(?<=\S)\$(?!\d)"#)

    private static func split(_ s: String, _ regex: NSRegularExpression, _ make: (String) -> Piece) -> [Piece] {
        let ns = s as NSString
        var out: [Piece] = []
        var at = 0
        for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > at { out.append(.text(ns.substring(with: NSRange(location: at, length: m.range.location - at)))) }
            let g = (1..<m.numberOfRanges).first { m.range(at: $0).location != NSNotFound }
            let latex = g.map { ns.substring(with: m.range(at: $0)) } ?? ""
            let trimmed = latex.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(trimmed.isEmpty ? .text(ns.substring(with: m.range)) : make(trimmed))
            at = m.range.location + m.range.length
        }
        if at < ns.length { out.append(.text(ns.substring(from: at))) }
        return out
    }

    /// Prose and display equations, in order.
    static func blocks(_ s: String) -> [Piece] {
        guard s.contains("$$") || s.contains("\\[") else { return [.text(s)] }
        return split(s, displayRegex) { .block($0) }
    }

    /// One line of prose as text and inline equations, in order. A **bold** span with an equation inside keeps its bold:
    /// the markers go round its words only (as AutoMath does), so no stray ** is left on screen.
    static func inlinePieces(_ s: String) -> [Piece] {
        guard s.contains("**"), s.contains("$") || s.contains("\\(") else { return plainPieces(s) }
        let ns = s as NSString
        var out: [Piece] = []
        var at = 0
        for m in AutoMath.boldRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let inner = plainPieces(ns.substring(with: m.range(at: 1)))
            guard inner.contains(where: { if case .text = $0 { return false }; return true }) else { continue }
            if m.range.location > at { out += plainPieces(ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            for piece in inner {
                if case .text(let t) = piece { out.append(.text(AutoMath.bold(t))) } else { out.append(piece) }
            }
            at = m.range.location + m.range.length
        }
        guard at > 0 else { return plainPieces(s) }
        if at < ns.length { out += plainPieces(ns.substring(from: at)) }
        return out
    }

    private static func plainPieces(_ s: String) -> [Piece] {
        let delimited = (s.contains("$") || s.contains("\\(")) ? split(s, inlineRegex) { .inline($0) } : [.text(s)]
        // Plain-text maths between the marked pieces gets found too.
        return delimited.flatMap { piece -> [Piece] in
            if case .text(let t) = piece { return AutoMath.split(t) }
            return [piece]
        }
    }

    /// Commands models write that SwiftMath doesn't know, rewritten to ones it draws (checked with --livecheck only=symbols).
    static let substitutes: [(pattern: String, with: String)] = [
        (#"\\[dt]frac(?![A-Za-z])"#, #"\\frac"#),
        (#"\\implies(?![A-Za-z])"#, #"\\Longrightarrow"#),
        // The maths font has no ∴ or ∵ (SwiftMath silently leaves out a glyph it lacks), so they are spelled out.
        (#"\\therefore(?![A-Za-z])\s*"#, #"\\text{therefore }"#),
        (#"\\because(?![A-Za-z])\s*"#, #"\\text{because }"#),
        (#"\\boxed\{([^{}]*)\}"#, "$1"),
    ]

    /// \checkmark has no glyph in the maths font either: it is taken out and a ✓ is shown after the equation as text.
    private static let checkmark = #"\s*\\checkmark(?![A-Za-z])"#

    /// The LaTeX as SwiftMath gets it (`substitutes` applied, check marks out), and the text to show after it.
    static func prepared(_ latex: String) -> (latex: String, after: String) {
        guard latex.contains("\\") else { return (latex, "") }
        var s = substitutes.reduce(latex) { $0.replacingOccurrences(of: $1.pattern, with: $1.with, options: .regularExpression) }
        var after = ""
        if s.range(of: checkmark, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: checkmark, with: "", options: .regularExpression)
            after = " ✓"
        }
        return (s, after)
    }

    /// What is shown when an equation can't be typeset: readable plain maths through MathPretty, never a raw \command.
    /// (MarkdownText.inline prettifies it again on the way to the screen; that second pass changes nothing.)
    static func fallbackText(_ latex: String) -> String {
        var s = latex
        // Environments: the \begin/\end lines go, rows become "; " and alignment marks go.
        s = s.replacingOccurrences(of: #"\\(?:begin|end)\{[A-Za-z*]+\}"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*\\\\\s*"#, with: "; ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s*&\s*(?=[=<>≤≥≈])"#, with: " ", options: .regularExpression) // aligned: "x &= 1"
        s = s.replacingOccurrences(of: #"\s*&\s*"#, with: ", ", options: .regularExpression)            // cases: "1 & x > 0"
        s = MathPretty.prettify(s)
        // Anything MathPretty doesn't know: the command name goes, what it applied to stays.
        s = s.replacingOccurrences(of: #"\\[A-Za-z]+\*?"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\(.)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "{", with: "").replacingOccurrences(of: "}", with: "")
        return s.replacingOccurrences(of: #" {2,}"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }

    final class Rendered {
        let image: NSImage?
        let descent: CGFloat
        /// Text shown right after the image (a ✓ the maths font can't draw).
        let after: String
        init(_ image: NSImage?, _ descent: CGFloat, after: String = "") { self.image = image; self.descent = descent; self.after = after }
    }

    /// Typeset equations, newest 256 kept. A plain dictionary rather than NSCache, which drops entries whenever it likes.
    static let cacheLimit = 256
    static let cache = BoundedCache<String, Rendered>(limit: cacheLimit)

    /// The typeset equation, or nil when SwiftMath can't read it. Cached per text, size, mode and appearance.
    static func render(_ latex: String, size: CGFloat, display: Bool, dark: Bool) -> Rendered {
        let key = "\(dark ? "d" : "l")|\(display ? "D" : "T")|\(size)|\(latex)"
        if let hit = cache.value(for: key) { return hit }
        let colour = Theme.ink.resolved(dark: dark)
        let source = prepared(latex)
        var img = MathImage(latex: source.latex, fontSize: size, textColor: colour,
                            labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, info) = img.asImage()
        let result = Rendered(error == nil ? image : nil, info?.descent ?? 0, after: source.after)
        cache.insert(result, for: key)
        return result
    }
}

/// A small cache that keeps the newest `limit` entries (oldest out first). Locked, so any thread may use it.
final class BoundedCache<Key: Hashable, Value: AnyObject> {
    let limit: Int
    private var store: [Key: Value] = [:]
    private var order: [Key] = []
    private let lock = NSLock()

    init(limit: Int) { self.limit = max(1, limit) }

    func value(for key: Key) -> Value? {
        lock.lock(); defer { lock.unlock() }
        return store[key]
    }

    func insert(_ value: Value, for key: Key) {
        lock.lock(); defer { lock.unlock() }
        if store.updateValue(value, forKey: key) == nil { order.append(key) }
        while order.count > limit { store.removeValue(forKey: order.removeFirst()) }
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return store.count
    }
}

/// A line of an answer: markdown text with any inline equations set in as images on the text baseline.
/// Key words the model marked (`==like this==`, see Highlights) are drawn with a soft rounded tint behind them.
struct MathLine: View {
    let text: String
    var streaming = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let soft = streaming ? MarkdownText.softenPartial(text) : text
        // Marks become two private-use characters here (a half-arrived `==word` loses its markers while streaming).
        let shown = Highlights.encode(soft, streaming: streaming)
        let pieces = MathRender.inlinePieces(shown)
        let marked = shown.contains(Highlights.open)
        Group {
            if marked {
                Self.highlighted(pieces, dark: scheme == .dark)
                    .backgroundPreferenceValue(Text.LayoutKey.self) { HighlightBackground(layouts: $0, tint: Highlights.tint(dark: scheme == .dark)) }
            } else if pieces.count == 1, case .text(let t) = pieces[0] {
                Text(MarkdownText.inline(t))
            } else {
                pieces.reduce(Text("")) { acc, piece in
                    switch piece {
                    case .text(let t):
                        return acc + Text(MarkdownText.inline(t))
                    case .auto(let latex, let raw):
                        let r = MathRender.render(latex, size: 15, display: false, dark: scheme == .dark)
                        guard let image = r.image else { return acc + Text(MarkdownText.inline(raw)) }
                        return acc + Text(Image(nsImage: image)).baselineOffset(-r.descent) + Text(r.after)
                    case .inline(let latex), .block(let latex):
                        let r = MathRender.render(latex, size: 15, display: false, dark: scheme == .dark)
                        guard let image = r.image else { return acc + Text(MarkdownText.inline(MathRender.fallbackText(latex))) }
                        return acc + Text(Image(nsImage: image)).baselineOffset(-r.descent) + Text(r.after)
                    }
                }
            }
        }
        .font(.mBody).lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The same line when it has marks: the text and the equations in order, the marked stretches tagged for the renderer.
    /// The marks went through markdown as characters, so **bold** and `code` around or inside a mark still work.
    static func highlighted(_ pieces: [MathRender.Piece], dark: Bool) -> Text {
        var inside = false
        func tag(_ text: Text, _ marked: Bool) -> Text { marked ? text.customAttribute(HighlightMark()) : text }
        /// A piece that isn't prose (an equation): its marker characters only move the state.
        func clean(_ s: String) -> (String, startsInside: Bool) {
            let was = inside
            for ch in s { if ch == Highlights.open { inside = true } else if ch == Highlights.close { inside = false } }
            let cleaned = s.replacingOccurrences(of: String(Highlights.open), with: "").replacingOccurrences(of: String(Highlights.close), with: "")
            return (cleaned, was || s.contains(Highlights.open))
        }
        return pieces.reduce(Text("")) { acc, piece in
            switch piece {
            case .text(let t):
                return MarkdownText.highlightRuns(MarkdownText.inline(t), inside: &inside).reduce(acc) { $0 + tag(Text($1.text), $1.marked) }
            case .auto(let latex, let raw):
                let (shownRaw, marked) = clean(raw)
                let r = MathRender.render(Highlights.withoutMarkers(latex), size: 15, display: false, dark: dark)
                guard let image = r.image else { return acc + tag(Text(MarkdownText.inline(shownRaw)), marked) }
                return acc + tag(Text(Image(nsImage: image)).baselineOffset(-r.descent) + Text(r.after), marked)
            case .inline(let latex), .block(let latex):
                let (l, marked) = clean(latex)
                let r = MathRender.render(l, size: 15, display: false, dark: dark)
                guard let image = r.image else { return acc + tag(Text(MarkdownText.inline(MathRender.fallbackText(l))), marked) }
                return acc + tag(Text(Image(nsImage: image)).baselineOffset(-r.descent) + Text(r.after), marked)
            }
        }
    }
}

/// Tags the text a mark covers, so `HighlightBackground` knows where to paint.
struct HighlightMark: TextAttribute {}

/// A soft rounded tint behind each marked stretch of a line (one shape per stretch on each line, so a mark that wraps
/// gets a shape on both lines). It sits behind the text, which keeps its own colour and weight, and it is drawn from the
/// text's layout rather than by a custom text renderer: a custom renderer switches off text selection, and answers must
/// stay selectable and copyable.
struct HighlightBackground: View {
    let layouts: [Text.LayoutKey.AnchoredLayout]
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            let shapes = Self.shapes(layouts, in: geo)
            Canvas { context, _ in
                for r in shapes {
                    context.fill(Path(roundedRect: r, cornerRadius: 4, style: .continuous), with: .color(tint))
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func shapes(_ layouts: [Text.LayoutKey.AnchoredLayout], in geo: GeometryProxy) -> [CGRect] {
        var out: [CGRect] = []
        for item in layouts {
            let origin = geo[item.origin]
            for line in item.layout {
                var onLine: [CGRect] = []
                for run in line where run[HighlightMark.self] != nil {
                    let r = run.typographicBounds.rect
                    if let last = onLine.last, abs(last.maxX - r.minX) < 1.5 { onLine[onLine.count - 1] = last.union(r) } else { onLine.append(r) }
                }
                out += onLine.map { $0.insetBy(dx: -2.5, dy: 0.5).offsetBy(dx: origin.x, dy: origin.y) }
            }
        }
        return out
    }
}

/// An equation on its own line, larger, scrolling sideways if it's wider than the popup.
struct MathBlock: View {
    let latex: String
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let r = MathRender.render(latex, size: 18, display: true, dark: scheme == .dark)
        if let image = r.image {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    Image(nsImage: image).renderingMode(.original)
                    if !r.after.isEmpty { Text(r.after).font(.mBody) }
                }
                .padding(.vertical, 4)
            }
            .accessibilityLabel(latex)
        } else {
            Text(MarkdownText.inline(MathRender.fallbackText(latex))).font(.mBody).fixedSize(horizontal: false, vertical: true)
        }
    }
}
