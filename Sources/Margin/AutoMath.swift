import Foundation

/// Finds plain-text maths the model forgot to wrap in `$…$` (x^(-3/2), 1/x^(3/2), 3/(2√x), dy/dx = …) and turns it into LaTeX,
/// so it gets typeset anyway. It's strict on purpose: an expression is only touched when it holds a caret, a root, or a
/// fraction with both a number and a letter in it ("24/7", "I/O" and "and/or" stay as they are), and anything it can't read
/// completely stays exactly as written.
enum AutoMath {
    /// Prose split into plain text and typeset maths (`raw` is what to show if the maths can't be drawn).
    static func split(_ s: String) -> [MathRender.Piece] {
        s.contains("**") ? splitBold(s) : splitPlain(s)
    }

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)

    /// Maths inside **bold** text: the bold markers go round the words only, so no stray asterisks end up on screen.
    private static func splitBold(_ s: String) -> [MathRender.Piece] {
        let ns = s as NSString
        var out: [MathRender.Piece] = []
        var at = 0
        for m in boldRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            let sub = splitPlain(ns.substring(with: m.range(at: 1)))
            guard sub.contains(where: { if case .auto = $0 { return true }; return false }) else { continue }
            if m.range.location > at { out += splitPlain(ns.substring(with: NSRange(location: at, length: m.range.location - at))) }
            for piece in sub {
                if case .text(let t) = piece { out.append(.text(bold(t))) } else { out.append(piece) }
            }
            at = m.range.location + m.range.length
        }
        guard at > 0 else { return splitPlain(s) }
        if at < ns.length { out += splitPlain(ns.substring(from: at)) }
        return out
    }

    /// `text` in bold, with spaces (and bare punctuation) left outside the markers.
    private static func bold(_ t: String) -> String {
        let core = t.trimmingCharacters(in: .whitespacesAndNewlines)
        guard core.contains(where: \.isLetter) || core.contains(where: \.isNumber) else { return t }
        let lead = String(t.prefix(while: { $0.isWhitespace })), trail = String(t.reversed().prefix(while: { $0.isWhitespace }))
        return lead + "**" + core + "**" + trail
    }

    private static func splitPlain(_ s: String) -> [MathRender.Piece] {
        guard s.contains("^") || s.contains("√") || s.contains("/") || s.contains("sqrt") else { return [.text(s)] }
        let ns = s as NSString
        let tokens = wordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { $0.range }
        guard !tokens.isEmpty else { return [.text(s)] }

        enum Kind { case none, op, weak, solid }
        let kinds: [Kind] = tokens.map { r in
            let w = trimmed(ns.substring(with: r))
            if w.isEmpty { return .none }
            if opWords.contains(w) { return .op }
            guard isMathWord(w) else { return .none }
            if w.count == 1, w.first!.isLetter { return .weak }
            return .solid
        }
        // A lone letter only counts beside an operator ("x = 5"), so "a" and "I" in a sentence are left alone.
        var ok = kinds.map { $0 == .solid || $0 == .op }
        for i in kinds.indices where kinds[i] == .weak {
            let prevOp = i > 0 && kinds[i - 1] == .op, nextOp = i + 1 < kinds.count && kinds[i + 1] == .op
            ok[i] = prevOp || nextOp
        }

        var pieces: [MathRender.Piece] = []
        var at = 0 // UTF-16 offset up to which text has been emitted
        var i = 0
        while i < tokens.count {
            guard ok[i] else { i += 1; continue }
            var j = i
            // A word that ends with punctuation ends the run: the next one starts a new clause.
            func endsClause(_ k: Int) -> Bool { ".,;:!?".contains(ns.substring(with: tokens[k]).last ?? " ") }
            while j + 1 < tokens.count, ok[j + 1], j - i < 12, !endsClause(j) { j += 1 }
            var lo = i, hi = j
            // Trim operators (and lone letters left with no operator beside them) off both ends.
            func edgeBad(_ k: Int, other: Int) -> Bool {
                kinds[k] == .op || (kinds[k] == .weak && !(kinds[other] == .op))
            }
            while lo <= hi, edgeBad(lo, other: min(lo + 1, hi)) { lo += 1 }
            while hi >= lo, edgeBad(hi, other: max(hi - 1, lo)) { hi -= 1 }
            defer { i = j + 1 }
            guard lo <= hi else { continue }

            var range = NSRange(location: tokens[lo].location, length: tokens[hi].location + tokens[hi].length - tokens[lo].location)
            // Punctuation after the last word belongs to the sentence, not the maths.
            var tail = ""
            var runText = ns.substring(with: range)
            while let last = runText.last, ".,;:!?".contains(last) { tail = String(last) + tail; runText.removeLast() }
            range.length = (runText as NSString).length
            guard hasMarker(runText), let latex = toLatex(runText) else { continue }

            if range.location > at { pieces.append(.text(ns.substring(with: NSRange(location: at, length: range.location - at)))) }
            pieces.append(.auto(latex, raw: runText))
            at = range.location + range.length
        }
        guard !pieces.isEmpty else { return [.text(s)] }
        if at < ns.length { pieces.append(.text(ns.substring(from: at))) }
        return pieces
    }

    // MARK: Spotting it

    private static let opWords: Set<String> = ["+", "-", "−", "–", "=", "≈", "≠", "≤", "≥", "<", ">"]
    private static let wordRegex = try! NSRegularExpression(pattern: #"\S+"#)
    private static let allowedNames = try! NSRegularExpression(pattern: #"sqrt|sin|cos|tan|log|ln|pi|dx|dy|dt|dz|d[A-Za-z](?=/d[A-Za-z])|(?<=/)d[A-Za-z]"#)
    private static let moreLetters = try! NSRegularExpression(pattern: #"[A-Za-z]{2,}"#)
    private static let dateLike = try! NSRegularExpression(pattern: #"\d+/\d+/\d+"#)
    private static let strayDot = try! NSRegularExpression(pattern: #"(?<!\d)\.|\.(?!\d)"#)
    private static let letterDigit = try! NSRegularExpression(pattern: #"[A-Za-z]\d"#)

    private static func trimmed(_ w: String) -> String {
        var t = w
        while let last = t.last, ".,;:!?".contains(last) { t.removeLast() }
        return t
    }

    private static func firstMatch(_ r: NSRegularExpression, _ s: String) -> Bool {
        r.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }

    /// A word made only of maths characters, with no ordinary word in it.
    private static func isMathWord(_ w: String) -> Bool {
        guard w.allSatisfy({ $0.isASCII ? ($0.isLetter || $0.isNumber || "()+-/^=.<>".contains($0)) : "√π−–·⋅×÷≈≠≤≥".contains($0) }) else { return false }
        if w.contains("://") || firstMatch(strayDot, w) { return false }
        let bare = allowedNames.stringByReplacingMatches(in: w, range: NSRange(location: 0, length: (w as NSString).length), withTemplate: " ")
        return !firstMatch(moreLetters, bare) && w.contains(where: { $0.isLetter || $0.isNumber || $0 == "√" || $0 == "π" })
    }

    /// Strong enough evidence that this is maths and not prose.
    private static func hasMarker(_ run: String) -> Bool {
        if run.contains("^") || run.contains("√") || run.contains("sqrt") { return true }
        guard run.contains("/"), !firstMatch(dateLike, run), !firstMatch(letterDigit, run) else { return false }
        return run.contains(where: \.isNumber) && run.contains(where: \.isLetter)
    }

    // MARK: Reading it

    private static func toLatex(_ run: String) -> String? {
        var p = Parser(Array(run))
        guard let e = p.expr(), p.atEnd, e.count < 400 else { return nil }
        return e
    }

    /// A small reader for the kinds of expressions that turn up in an explanation. `nil` anywhere means "leave it alone".
    private struct Parser {
        var c: [Character]
        var i = 0
        init(_ chars: [Character]) { c = chars }

        var atEnd: Bool { var k = i; while k < c.count, c[k] == " " { k += 1 }; return k == c.count }
        var peek: Character? { i < c.count ? c[i] : nil }
        mutating func ws() { while i < c.count, c[i] == " " { i += 1 } }

        /// `inner` is set for a whole "(…)" group, so a fraction can drop the brackets round its top or bottom.
        struct Part { var tex: String; var inner: String? = nil }

        // expr := term (("+" | "-" | "=") term)*
        mutating func expr() -> String? {
            guard let first = term() else { return nil }
            var out = first.tex
            while true {
                let save = i
                ws()
                guard let op = peek, "+-−–=≈≠≤≥<>".contains(op) else { i = save; break }
                i += 1
                ws()
                guard let t = term() else { return nil }
                let sign: String
                switch op {
                case "+": sign = " + "
                case "-", "−", "–": sign = " - "
                case "≈": sign = " \\approx "
                case "≠": sign = " \\neq "
                case "≤": sign = " \\leq "
                case "≥": sign = " \\geq "
                default: sign = " \(op) "
                }
                out += sign + t.tex
            }
            return out
        }

        // term := factor (factor | "/" factor)*, where a "/" divides the factor just before it
        mutating func term() -> Part? {
            var parts: [Part] = []
            guard let f = factor() else { return nil }
            parts.append(f)
            while let ch = peek {
                if ch == "/" {
                    i += 1
                    guard let den = factor(), let num = parts.popLast() else { return nil }
                    if num.inner == nil, num.tex.hasPrefix("-") {
                        parts.append(Part(tex: "-\\frac{\(num.tex.dropFirst())}{\(den.inner ?? den.tex)}")) // the minus sign goes in front
                    } else {
                        parts.append(Part(tex: "\\frac{\(num.inner ?? num.tex)}{\(den.inner ?? den.tex)}"))
                    }
                } else if "·⋅×÷".contains(ch) {
                    i += 1
                    guard let g = factor() else { return nil }
                    parts.append(Part(tex: ch == "÷" ? "\\div " : (ch == "×" ? "\\times " : "\\cdot ")))
                    parts.append(g)
                } else if ch.isLetter || ch.isNumber || "(√π".contains(ch) {
                    guard let g = factor() else { return nil }
                    parts.append(g)
                } else { break }
            }
            return parts.count == 1 ? parts[0] : Part(tex: parts.map(\.tex).joined())
        }

        // factor := "-"? base ("^" exponent)?
        mutating func factor() -> Part? {
            var sign = ""
            if let ch = peek, ch == "-" || ch == "−" || ch == "–" { sign = "-"; i += 1 }
            guard let b = base() else { return nil }
            if peek == "^" {
                i += 1
                guard let e = exponent() else { return nil }
                return Part(tex: sign + b.tex + "^{\(e)}")
            }
            return Part(tex: sign + b.tex, inner: sign.isEmpty ? b.inner : nil)
        }

        mutating func exponent() -> String? {
            guard let ch = peek else { return nil }
            if ch == "(" {
                i += 1
                guard let e = expr(), peek == ")" else { return nil }
                i += 1
                return e
            }
            var sign = ""
            if ch == "-" || ch == "−" { sign = "-"; i += 1 }
            guard let n = peek else { return nil }
            if n.isNumber {
                let top = number()
                // Only a negative exponent takes a fraction ("x^-3/2"); "x^2/3" is x² over 3.
                if sign == "-", peek == "/", i + 1 < c.count, c[i + 1].isNumber {
                    i += 1
                    return "-\\frac{\(top)}{\(number())}"
                }
                return sign + top
            }
            if n.isLetter, i + 1 >= c.count || !c[i + 1].isLetter { i += 1; return sign + String(n) }
            return nil
        }

        mutating func number() -> String {
            var s = ""
            while let ch = peek, ch.isNumber { s.append(ch); i += 1 }
            if peek == ".", i + 1 < c.count, c[i + 1].isNumber {
                s.append("."); i += 1
                while let ch = peek, ch.isNumber { s.append(ch); i += 1 }
            }
            return s
        }

        mutating func base() -> Part? {
            guard let ch = peek else { return nil }
            if ch.isNumber { return Part(tex: number()) }
            if ch == "π" { i += 1; return Part(tex: "\\pi") }
            if ch == "(" {
                i += 1
                guard let e = expr(), peek == ")" else { return nil }
                i += 1
                return Part(tex: "(\(e))", inner: e)
            }
            if ch == "√" {
                i += 1
                if peek == "(" {
                    i += 1
                    guard let e = expr(), peek == ")" else { return nil }
                    i += 1
                    return Part(tex: "\\sqrt{\(e)}")
                }
                if let n = peek, n.isNumber { return Part(tex: "\\sqrt{\(number())}") }
                if let n = peek, n.isLetter { i += 1; return Part(tex: "\\sqrt{\(n)}") }
                return nil
            }
            if ch.isLetter {
                var word = ""
                var k = i
                while k < c.count, c[k].isLetter { word.append(c[k]); k += 1 }
                switch word {
                case "sqrt":
                    i = k
                    guard peek == "(" else { return nil }
                    i += 1
                    guard let e = expr(), peek == ")" else { return nil }
                    i += 1
                    return Part(tex: "\\sqrt{\(e)}")
                case "sin", "cos", "tan", "log", "ln":
                    i = k
                    guard peek == "(" else { return nil }
                    i += 1
                    guard let e = expr(), peek == ")" else { return nil }
                    i += 1
                    return Part(tex: "\\\(word)\\left(\(e)\\right)")
                case "pi": i = k; return Part(tex: "\\pi")
                case "dx", "dy", "dt", "dz": i = k; return Part(tex: word)
                default:
                    // dA/dr, dV/dt…: a "d" and a letter, right beside a "/"
                    if word.count == 2, word.first == "d", (k < c.count && c[k] == "/") || (i > 0 && c[i - 1] == "/") { i = k; return Part(tex: word) }
                    guard word.count == 1 else { return nil }
                    i += 1
                    return Part(tex: word)
                }
            }
            return nil
        }
    }
}
