import Foundation
import SwiftUI

/// Key-word highlights: with Learn mode on, Merlin marks the few words that carry an answer's key ideas as `==like this==`.
/// This is the one small pure helper everything shares: the answer view draws the marked words, and everything else that
/// takes answer text (copying, the Library's previews and search, speech, chat naming, quizzes, the MCP server) uses
/// `strip` so no raw `==` reaches a person.
///
/// A mark is `==` + text + `==` on ONE line. The text starts and ends with a non-space, is at most `maxLength` characters,
/// and the markers aren't glued to words or other `=` signs, so `a == b`, `a==b`, `===` and `x >= y` are never marks.
/// Code (inline and fenced), maths (`$…$`, `$$…$$`, `\(…\)`, `\[…\]`), links and `<say>` clips are left exactly as written.
enum Highlights {
    static let maxLength = 80

    /// Stand-ins for a mark's two ends while a line goes through markdown, maths and the typesetter (private-use characters,
    /// away from the ones MathPretty uses). The answer view turns them into a highlighted run and never shows them.
    static let open: Character = "\u{E010}", close: Character = "\u{E011}"
    private static let openU: UInt16 = 0xE010, closeU: UInt16 = 0xE011

    /// The tint behind a marked word: the app's accent at low opacity (it follows Settings → Appearance), stronger in dark.
    static func tint(dark: Bool) -> Color { Theme.accent.color.opacity(dark ? 0.30 : 0.38) }

    /// `s` without the stand-in characters.
    static func withoutMarkers(_ s: String) -> String {
        s.replacingOccurrences(of: String(open), with: "").replacingOccurrences(of: String(close), with: "")
    }

    // MARK: Finding marks

    /// What a scan found, as UTF-16 offsets into the text.
    struct Scan {
        /// The two `==` of each complete mark: (opening marker start, closing marker start).
        var pairs: [(open: Int, close: Int)] = []
        /// Openers (`==` right before a non-space) with no closer on their line: a mark still arriving, or one never closed.
        /// They are dropped from what is shown and stripped, like a half-arrived one.
        var dangling: [Int] = []
    }

    private static let protectedRegexes: [NSRegularExpression] = [
        // Voice clips and the other tags the app turns into widgets.
        #"<(?:say|graph|quiz|event|meta|drawing|writing)\b.*?</(?:say|graph|quiz|event|meta|drawing|writing)>"#,
        // Display and inline maths (the same shapes MathRender typesets).
        #"\$\$.+?\$\$|\\\[.+?\\\]"#,
        #"\\\(.+?\\\)|(?<![\\$\w])\$(?=[^\s$])[^$\n]+?(?<=\S)\$(?!\d)"#,
        // A link's address and a bare web address.
        #"\]\([^)\s]*\)"#,
        #"https?://[^\s)\]>]+"#,
    ].map { try! NSRegularExpression(pattern: $0, options: [.dotMatchesLineSeparators]) }

    /// Which UTF-16 positions are code, maths, a link or a clip (a mark's `==` is never read from there).
    private static func protectedMask(_ s: String, _ u: [UInt16]) -> [Bool] {
        var mask = [Bool](repeating: false, count: u.count)
        func cover(_ from: Int, _ to: Int) { for i in max(0, from)..<min(to, u.count) { mask[i] = true } }
        let tick: UInt16 = 0x60
        // Code: ``` fences (an unclosed one runs to the end), then `inline code` of the same number of backticks.
        var i = 0
        while i < u.count {
            guard u[i] == tick else { i += 1; continue }
            var n = 0
            while i + n < u.count, u[i + n] == tick { n += 1 }
            var j = i + n
            var end: Int?
            while j < u.count {
                guard u[j] == tick else { j += 1; continue }
                var m = 0
                while j + m < u.count, u[j + m] == tick { m += 1 }
                if m == n { end = j + m; break }
                j += m
            }
            if let end { cover(i, end); i = end }
            else if n >= 3 { cover(i, u.count); i = u.count } // an unclosed fence
            else { i += n }
        }
        let ns = s as NSString
        for regex in protectedRegexes {
            for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)) { cover(m.range.location, m.range.location + m.range.length) }
        }
        return mask
    }

    private static func isWordChar(_ c: UInt16) -> Bool {
        if (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F { return true }
        guard c > 0x7F, let scalar = Unicode.Scalar(c) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSpace(_ c: UInt16) -> Bool { c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0xA0 }

    static func scan(_ s: String) -> Scan {
        let u = Array(s.utf16)
        var out = Scan()
        guard s.contains("==") else { return out }
        let mask = protectedMask(s, u)
        let eq: UInt16 = 0x3D, nl: UInt16 = 0x0A
        /// The `=` run starting at i (0 when there isn't one, or it's inside protected text).
        func run(_ i: Int) -> Int {
            var n = 0
            while i + n < u.count, u[i + n] == eq, !mask[i + n] { n += 1 }
            return n
        }
        var i = 0
        while i < u.count {
            guard u[i] == eq, !mask[i] else { i += 1; continue }
            let n = run(i)
            var next = i + n
            if n == 2, i == 0 || !isWordChar(u[i - 1]), i + 2 < u.count, !isSpace(u[i + 2]) {
                // An opener. Look for its closer on the same line.
                var j = i + 2
                var closer: Int?
                while j < u.count, u[j] != nl {
                    if u[j] == eq, !mask[j] {
                        let m = run(j)
                        if m == 2, j > i + 2, !isSpace(u[j - 1]), j + 2 >= u.count || !isWordChar(u[j + 2]) {
                            closer = j
                            break
                        }
                        j += max(m, 1)
                    } else { j += 1 }
                }
                if let closer {
                    // A span over the limit is no mark: both `==` stay as written.
                    if closer - (i + 2) <= maxLength { out.pairs.append((i, closer)) }
                    next = closer + 2
                } else {
                    out.dangling.append(i) // opened, never closed on its line
                }
            }
            i = next
        }
        return out
    }

    // MARK: Using them

    /// `s` without the markers of complete marks: the plain words.
    static func strip(_ s: String) -> String {
        guard s.contains("==") else { return s }
        return rebuild(s, scan(s)) { _ in "" }
    }

    /// `s` as text and whether each stretch is marked. Joined, the texts are `strip(s)`.
    static func split(_ s: String) -> [(text: String, marked: Bool)] {
        var out: [(text: String, marked: Bool)] = []
        var current = "", marked = false
        func flush() { if !current.isEmpty { out.append((current, marked)); current = "" } }
        for ch in encode(s) {
            if ch == open { flush(); marked = true } else if ch == close { flush(); marked = false } else { current.append(ch) }
        }
        flush()
        return out
    }

    /// The answer text on its way to the screen: each complete mark's `==` pair becomes `open` and `close`. An opener with
    /// no closer on its line (half-arrived, or never closed) loses its `==`, and while the answer is still arriving a
    /// trailing `=` or `==` does too, so nothing raw flashes. A stray `open` or `close` already in the text is dropped first.
    static func encode(_ s: String, streaming: Bool = false) -> String {
        var text = s
        if text.contains(open) || text.contains(close) {
            text = text.replacingOccurrences(of: String(open), with: "").replacingOccurrences(of: String(close), with: "")
        }
        guard text.contains("=") else { return text }
        let found = scan(text)
        var out = rebuild(text, found) { isOpen in String(isOpen ? open : close) }
        if streaming {
            // A lone `=` or `==` at the very end may be the start of a marker.
            if out.hasSuffix("==") { out.removeLast(2) } else if out.hasSuffix("=") { out.removeLast() }
        }
        return out
    }

    /// Whether the text has at least one complete mark.
    static func hasMarks(_ s: String) -> Bool { !scan(s).pairs.isEmpty }

    /// `s` with each complete mark's two `==` replaced by `marker(isOpening)`, and the `==` of each dangling opener removed.
    private static func rebuild(_ s: String, _ found: Scan, _ marker: (Bool) -> String) -> String {
        let u = Array(s.utf16)
        var edits: [(at: Int, with: String)] = found.pairs.flatMap { [($0.open, marker(true)), ($0.close, marker(false))] }
        edits += found.dangling.map { ($0, "") }
        edits.sort { $0.at < $1.at }
        var out: [UInt16] = []
        var at = 0
        for edit in edits {
            out += u[at..<edit.at]
            out += Array(edit.with.utf16)
            at = edit.at + 2
        }
        out += u[at...]
        return String(decoding: out, as: UTF16.self)
    }
}
