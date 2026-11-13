import Foundation
import SwiftUI

/// Makes the maths in an answer readable: LaTeX turns into symbols (\theta → θ, \frac{a}{b} → (a)/(b)),
/// and `u_y` / `t^2` / `m s^-2` get a real lowered / raised small size instead of a bare "_" or "^".
/// Only the display changes (copying and searching still see what Claude wrote), and `code` spans are left alone.
enum MathPretty {
    // Private-use marks: they ride through the markdown parser untouched, then `style` turns them into small raised/lowered text.
    static let subOpen: Character = "\u{E001}", subClose: Character = "\u{E002}"
    static let supOpen: Character = "\u{E003}", supClose: Character = "\u{E004}"

    private static let symbols: [String: String] = [
        "alpha": "α", "beta": "β", "gamma": "γ", "delta": "δ", "epsilon": "ε", "varepsilon": "ε", "zeta": "ζ", "eta": "η",
        "theta": "θ", "vartheta": "θ", "iota": "ι", "kappa": "κ", "lambda": "λ", "mu": "μ", "nu": "ν", "xi": "ξ", "pi": "π",
        "rho": "ρ", "sigma": "σ", "tau": "τ", "upsilon": "υ", "phi": "φ", "varphi": "φ", "chi": "χ", "psi": "ψ", "omega": "ω",
        "Gamma": "Γ", "Delta": "Δ", "Theta": "Θ", "Lambda": "Λ", "Xi": "Ξ", "Pi": "Π", "Sigma": "Σ", "Phi": "Φ", "Psi": "Ψ", "Omega": "Ω",
        "times": "×", "cdot": "·", "div": "÷", "pm": "±", "mp": "∓", "approx": "≈", "neq": "≠", "ne": "≠", "leq": "≤", "le": "≤",
        "geq": "≥", "ge": "≥", "to": "→", "rightarrow": "→", "leftarrow": "←", "Rightarrow": "⇒", "implies": "⇒", "leftrightarrow": "↔",
        "infty": "∞", "circ": "°", "degree": "°", "propto": "∝", "partial": "∂", "nabla": "∇", "sum": "Σ", "int": "∫",
        "equiv": "≡", "sim": "∼", "ll": "≪", "gg": "≫", "in": "∈", "cdots": "⋯", "ldots": "…", "dots": "…",
        "sin": "sin", "cos": "cos", "tan": "tan", "ln": "ln", "log": "log", "exp": "exp", "lim": "lim",
        "quad": " ", "qquad": "  ", "left": "", "right": "", "displaystyle": "",
    ]

    /// LaTeX and plain-typed maths → symbols, with sub/superscripts marked for `style`.
    static func prettify(_ text: String) -> String {
        // Leave `code` alone: only the even pieces (outside backticks) are touched.
        let pieces = text.components(separatedBy: "`")
        guard pieces.count > 1 else { return pretty(text) }
        return pieces.enumerated().map { $0.offset % 2 == 0 ? pretty($0.element) : $0.element }.joined(separator: "`")
    }

    private static func pretty(_ input: String) -> String {
        var s = input
        guard s.contains(where: { "\\^_$".contains($0) }) else { return s }
        // $…$, \(…\), \[…\] around maths: drop the fences (a "$5" price has no backslash or ^ inside, so it stays).
        s = s.replacingOccurrences(of: #"\$\$?([^$\n]*[\\^_][^$\n]*)\$\$?"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\[()\[\]]"#, with: "", options: .regularExpression)
        // \frac{a}{b} and \sqrt{x}, innermost first.
        for _ in 0..<4 {
            let before = s
            s = replace(s, #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#) { m in group(m[1]) + "/" + group(m[2]) }
            s = replace(s, #"\\sqrt\{([^{}]*)\}"#) { m in "√" + group(m[1]) }
            s = replace(s, #"\\(?:text|mathrm|mathbf|operatorname|mathit)\{([^{}]*)\}"#) { m in m[1] }
            if s == before { break }
        }
        // \theta, \times, \cdot …
        s = replace(s, #"\\([A-Za-z]+)"#) { m in symbols[m[1]] ?? m[0] }
        s = s.replacingOccurrences(of: #"\\[,;!:]"#, with: " ", options: .regularExpression)
        // Plain-typed: sqrt(x) → √(x), <= >= != → ≤ ≥ ≠.
        s = s.replacingOccurrences(of: #"\bsqrt\("#, with: "√(", options: .regularExpression)
        s = s.replacingOccurrences(of: "<=", with: "≤").replacingOccurrences(of: ">=", with: "≥").replacingOccurrences(of: "!=", with: "≠")

        // Subscripts: one-letter base, short subscript (so file_name, snake_case and URLs are left alone).
        s = replace(s, #"(?<![A-Za-z0-9_/.:~@])(?<![A-Za-z0-9]-)([A-Za-zΑ-Ωα-ω])_(\{[^{}]+\}|[A-Za-z0-9]{1,3})(?![A-Za-z0-9_])"#) { m in
            m[1] + String(subOpen) + unbrace(m[2]) + String(subClose)
        }
        // After a digit too: "2u_y" (the digit isn't part of a word).
        s = replace(s, #"(?<=[0-9])([A-Za-zΑ-Ωα-ω])_(\{[^{}]+\}|[A-Za-z0-9]{1,3})(?![A-Za-z0-9_])"#) { m in
            m[1] + String(subOpen) + unbrace(m[2]) + String(subClose)
        }
        // Superscripts: x^2, at^2, s^-2, 10^{-3}, e^{-x}.
        s = replace(s, #"(?<=[A-Za-z0-9)\]Α-Ωα-ω])\^(\{[^{}]+\}|[+\-−]?[0-9]+|[A-Za-z])(?![A-Za-z0-9])"#) { m in
            String(supOpen) + unbrace(m[1]).replacingOccurrences(of: "-", with: "−") + String(supClose)
        }
        return s
    }

    /// Small raised/lowered text for the marked runs (and the marks themselves removed).
    static func style(_ text: inout AttributedString, size: CGFloat = 14) {
        for (open, close, offset) in [(subOpen, subClose, -size * 0.22), (supOpen, supClose, size * 0.38)] {
            while let start = text.characters.firstIndex(of: open) {
                guard let end = text.characters[start...].firstIndex(of: close) else {
                    text.characters.remove(at: start) // a stray mark: just drop it
                    continue
                }
                let inner = text.index(afterCharacter: start)..<end
                text[inner].font = .geist(size * 0.72)
                text[inner].baselineOffset = offset
                text.characters.remove(at: end)
                text.characters.remove(at: start)
            }
        }
    }

    // MARK: helpers

    /// "a" stays "a"; "a+b" becomes "(a+b)" so a fraction reads right.
    private static func group(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        let simple = t.range(of: #"^[A-Za-z0-9.°αβγδθλμπρστφωΑ-Ωα-ω]+$"#, options: .regularExpression) != nil
        return simple ? t : "(" + t + ")"
    }

    private static func unbrace(_ s: String) -> String {
        s.hasPrefix("{") && s.hasSuffix("}") ? String(s.dropFirst().dropLast()) : s
    }

    /// Regex replace with a closure over the match's groups (0 = whole match).
    private static func replace(_ s: String, _ pattern: String, _ make: ([String]) -> String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups = (0..<m.numberOfRanges).map { i -> String in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            }
            out += make(groups)
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }
}
