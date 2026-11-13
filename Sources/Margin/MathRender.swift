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

    /// One line of prose as text and inline equations, in order.
    static func inlinePieces(_ s: String) -> [Piece] {
        let delimited = (s.contains("$") || s.contains("\\(")) ? split(s, inlineRegex) { .inline($0) } : [.text(s)]
        // Plain-text maths between the marked pieces gets found too.
        return delimited.flatMap { piece -> [Piece] in
            if case .text(let t) = piece { return AutoMath.split(t) }
            return [piece]
        }
    }

    final class Rendered {
        let image: NSImage?
        let descent: CGFloat
        init(_ image: NSImage?, _ descent: CGFloat) { self.image = image; self.descent = descent }
    }

    private static let cache = NSCache<NSString, Rendered>()

    /// The typeset equation, or nil when SwiftMath can't read it. Cached per text, size, mode and appearance.
    static func render(_ latex: String, size: CGFloat, display: Bool, dark: Bool) -> Rendered {
        let key = "\(dark ? "d" : "l")|\(display ? "D" : "T")|\(size)|\(latex)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let colour = Theme.ink.resolved(dark: dark)
        var img = MathImage(latex: latex, fontSize: size, textColor: colour,
                            labelMode: display ? .display : .text, textAlignment: .left)
        let (error, image, info) = img.asImage()
        let result = Rendered(error == nil ? image : nil, info?.descent ?? 0)
        cache.setObject(result, forKey: key)
        return result
    }
}

/// A line of an answer: markdown text with any inline equations set in as images on the text baseline.
struct MathLine: View {
    let text: String
    var streaming = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let shown = streaming ? MarkdownText.softenPartial(text) : text
        let pieces = MathRender.inlinePieces(shown)
        Group {
            if pieces.count == 1, case .text(let t) = pieces[0] {
                Text(MarkdownText.inline(t))
            } else {
                pieces.reduce(Text("")) { acc, piece in
                    switch piece {
                    case .text(let t):
                        return acc + Text(MarkdownText.inline(t))
                    case .auto(let latex, let raw):
                        let r = MathRender.render(latex, size: 15, display: false, dark: scheme == .dark)
                        guard let image = r.image else { return acc + Text(MarkdownText.inline(raw)) }
                        return acc + Text(Image(nsImage: image)).baselineOffset(-r.descent)
                    case .inline(let latex), .block(let latex):
                        let r = MathRender.render(latex, size: 15, display: false, dark: scheme == .dark)
                        guard let image = r.image else { return acc + Text(MarkdownText.inline(latex)) }
                        return acc + Text(Image(nsImage: image)).baselineOffset(-r.descent)
                    }
                }
            }
        }
        .font(.mBody).lineSpacing(4)
        .fixedSize(horizontal: false, vertical: true)
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
                Image(nsImage: image).renderingMode(.original)
                    .padding(.vertical, 4)
            }
            .accessibilityLabel(latex)
        } else {
            Text(MarkdownText.inline(latex)).font(.mBody).fixedSize(horizontal: false, vertical: true)
        }
    }
}
