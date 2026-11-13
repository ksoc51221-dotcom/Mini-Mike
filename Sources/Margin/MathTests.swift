import AppKit
import Foundation
import SwiftUI

extension FeatureTests {
    /// Maths in answers: LaTeX becomes symbols, u_y and t^2 get real sub/superscripts, code and plain words are left alone.
    static func mathChecks(_ check: (String, Bool) -> Void) {
        func plain(_ s: String) -> String {
            var a = AttributedString(MathPretty.prettify(s))
            MathPretty.style(&a)
            return String(a.characters)
        }
        func raised(_ s: String) -> [String] {
            var a = AttributedString(MathPretty.prettify(s))
            MathPretty.style(&a)
            return a.runs.filter { ($0.baselineOffset ?? 0) != 0 }.map { String(a[$0.range].characters) }
        }

        check("math: u_y is a lowered y", plain("so t = 2u_y / g") == "so t = 2uy / g" && raised("so t = 2u_y / g") == ["y"])
        check("math: v_0 and x_{max} lower", raised("v_0 and x_{max}") == ["0", "max"])
        check("math: at^2 raises the 2", plain("s = ut + at^2") == "s = ut + at2" && raised("s = ut + at^2") == ["2"])
        check("math: 10^{-3} raises with a real minus", raised("10^{-3}") == ["−3"])
        check("math: s^-2 raises", raised("m s^-2") == ["−2"])
        check("math: snake_case and file names are untouched", plain("use max_value in my_file.py and a_b_c") == "use max_value in my_file.py and a_b_c")
        check("math: URLs with underscores are untouched", plain("see https://x.com/a_b and /usr/a_b") == "see https://x.com/a_b and /usr/a_b")
        check("math: `code` spans are untouched", MathPretty.prettify("run `x_1 + y^2` now") == "run `x_1 + y^2` now")
        check("math: a price isn't maths", plain("it costs $5 and $10") == "it costs $5 and $10")
        check("math: greek and operators", plain(#"\theta = 45\degree, v \times t \approx 3"#) == "θ = 45°, v × t ≈ 3")
        check("math: \\frac", plain(#"\frac{v^2}{2g}"#) == "(v2)/2g" && raised(#"\frac{v^2}{2g}"#) == ["2"])
        check("math: \\frac with a sum gets brackets", plain(#"\frac{a+b}{2}"#) == "(a+b)/2")
        check("math: \\sqrt and fences", plain(#"$x = \sqrt{2}$"#) == "x = √2" && plain(#"\(a \leq b\)"#) == "a ≤ b")
        check("math: \\text and \\left \\right", plain(#"\left(\text{m/s}\right)"#) == "(m/s)")
        check("math: half-typed ^ doesn't break", plain("x^") == "x^" && plain("v_") == "v_")
        check("math: no marks are left behind", !plain("a_1 b^2 \\frac{c}{d}").contains { "\u{E001}\u{E002}\u{E003}\u{E004}".contains($0) })
        let shown = MarkdownText.inline("The time is t = 2u_y / g, about 2.57 s.")
        check("math: through the markdown renderer", String(shown.characters) == "The time is t = 2uy / g, about 2.57 s.")

        // The real typesetter (SwiftMath).
        let pieces = MathRender.inlinePieces("Speed $v_y$ and \\(\\theta\\) cost $5 and $10 today")
        check("render: finds $…$ and \\(…\\), leaves prices alone",
              pieces == [.text("Speed "), .inline("v_y"), .text(" and "), .inline("\\theta"), .text(" cost $5 and $10 today")])
        let blocks = MathRender.blocks("Roots:\n$$x = \\frac{-b}{2a}$$\nDone, or \\[a^2+b^2=c^2\\]")
        check("render: finds display equations", blocks.contains(.block("x = \\frac{-b}{2a}")) && blocks.contains(.block("a^2+b^2=c^2")) && blocks.count == 4)
        check("render: no maths is one piece of text", MathRender.blocks("plain words") == [.text("plain words")] && MathRender.inlinePieces("plain") == [.text("plain")])
        check("render: an empty $$ $$ stays text", MathRender.blocks("a $$ $$ b").allSatisfy { if case .block = $0 { return false }; return true })
        let eq = MathRender.render(#"x = \frac{-b \pm \sqrt{b^2 - 4ac}}{2a}"#, size: 18, display: true, dark: false)
        check("render: SwiftMath typesets a fraction and root (font found)", eq.image != nil && (eq.image?.size.width ?? 0) > 60 && (eq.image?.size.height ?? 0) > 20)
        let inline = MathRender.render(#"v_y"#, size: 15, display: false, dark: true)
        check("render: inline maths is small and sits on the baseline", inline.image != nil && (inline.image?.size.height ?? 99) < 30 && inline.descent >= 0)
        // NSCache may drop an entry whenever it likes (it does so more readily in a background process), so ask a few times.
        let cachedOnce = (0..<5).contains { _ in
            let first = MathRender.render(#"v_y"#, size: 15, display: false, dark: true)
            return MathRender.render(#"v_y"#, size: 15, display: false, dark: true) === first
        }
        check("render: the same equation is cached", cachedOnce)
        check("render: nonsense falls back (no image)", MathRender.render(#"\frac{"#, size: 15, display: false, dark: false).image == nil)
        check("render: the prompt now asks for LaTeX", Prompts.system(webSearch: false).contains("$$"))

        // Plain-text maths the model forgot to wrap in $…$ is typeset anyway.
        func autos(_ text: String) -> [String] { AutoMath.split(text).compactMap { if case .auto(let l, _) = $0 { return l }; return nil } }
        check("auto maths: the user's own question", autos("i got 3/2x^-1/2 + 2x^-3/2 but idk how to get the second one into a normal form")
              == [#"\frac{3}{2}x^{-\frac{1}{2}} + 2x^{-\frac{3}{2}}"#])
        check("auto maths: powers, fractions and roots in a chain", autos("x^(-3/2) = 1/x^(3/2) = 1/(x√x).")
              == [#"x^{-\frac{3}{2}} = \frac{1}{x^{\frac{3}{2}}} = \frac{1}{x\sqrt{x}}"#])
        check("auto maths: derivatives and bracketed fractions", autos("So dy/dx = 3/(2√x) + 2/(x√x).") == [#"\frac{dy}{dx} = \frac{3}{2\sqrt{x}} + \frac{2}{x\sqrt{x}}"#]
              && autos("get (3x + 4)/(2x√x).") == [#"\frac{3x + 4}{2x\sqrt{x}}"#])
        check("auto maths: x^2/2 is x² over 2, not x to the 2/2", autos("the area is x^2/2 + C") == [#"\frac{x^{2}}{2} + C"#])
        check("auto maths: sqrt( ) and a power of ten", autos("use sqrt(x) and 2^10 = 1024; e.g. a - b") == [#"\sqrt{x}"#, #"2^{10} = 1024"#])
        check("auto maths: en dashes, π and any dA/dr", autos("zero: dA/dr = 40 – (4 + π)r = 0, so") == [#"\frac{dA}{dr} = 40 - (4 + \pi)r = 0"#])
        check("auto maths: ≈ joins the expression", autos("r = 40/(4+π) ≈ 5.60 cm. Then A = 800/(4+π) ≈ 112 cm².")
              == [#"r = \frac{40}{4 + \pi} \approx 5.60"#, #"A = \frac{800}{4 + \pi} \approx 112"#])
        check("auto maths: dots and true minus signs", autos("x^(1/2)·x^(−1/2) = 1, and −1·x^(−1/2) = −x^(−1/2),")
              == [#"x^{\frac{1}{2}}\cdot x^{-\frac{1}{2}} = 1"#, #"-1\cdot x^{-\frac{1}{2}} = -x^{-\frac{1}{2}}"#])
        let boldMaths = AutoMath.split("leaving **x^(1/2) – x^(−1/2).** done")
        check("auto maths: inside bold, with no stray asterisks", boldMaths.contains(.auto(#"x^{\frac{1}{2}} - x^{-\frac{1}{2}}"#, raw: "x^(1/2) – x^(−1/2)"))
              && boldMaths.allSatisfy { if case .text(let t) = $0 { return !t.contains("**") || t.contains("**") && t.components(separatedBy: "**").count % 2 == 1 }; return true })
        check("auto maths: bold words keep their markers", AutoMath.split("**the answer is x^2 + 1** done").contains(.text("**the answer is** ")))
        check("auto maths: bold without maths is untouched", AutoMath.split("**just words** here") == [.text("**just words** here")])
        check("auto maths: prose is left alone", ["I/O and 24/7 and and/or", "on 3/4/2026 w/ a bit", "1/2 cup of flour", "a - b is fine, 5 - 3 too",
                                                   "see https://example.com/a/b^c", "the x-axis and well-known facts", "(see below) a bit of x"].allSatisfy { autos($0).isEmpty })
        check("auto maths: a list dash and the sentence's full stop stay outside",
              AutoMath.split("- x^2 is first.") == [.text("- "), .auto("x^{2}", raw: "x^2"), .text(" is first.")]
              && AutoMath.split("it is x^2.") == [.text("it is "), .auto("x^{2}", raw: "x^2"), .text(".")])
        check("auto maths: broken maths stays as written", autos("x^( and 3/(2√").isEmpty && autos("x^").isEmpty && autos("√").isEmpty)
        let flat = MathRender.inlinePieces("Then x^(-3/2) = 1/(x√x) here")
        check("auto maths: it comes through inlinePieces as typeset pieces", flat.count == 3 && { if case .auto = flat[1] { return true }; return false }())
        check("auto maths: marked maths still wins and isn't doubled", MathRender.inlinePieces("so $x^2$ and y") == [.text("so "), .inline("x^2"), .text(" and y")])
        check("auto maths: SwiftMath draws what it produced",
              MathRender.render(#"\frac{3}{2}x^{-\frac{1}{2}} + 2x^{-\frac{3}{2}}"#, size: 15, display: false, dark: true).image != nil
              && MathRender.render(#"\frac{dy}{dx} = \frac{3}{2\sqrt{x}} + \frac{2}{x\sqrt{x}}"#, size: 15, display: false, dark: false).image != nil)

        // The rule has to reach plain maths questions, not only graph ones (this was the "x^(-3/2) in plain text" bug).
        let asked = Prompts.features(question: "i got 3/2x^-1/2 + 2x^-3/2 but idk how to get the second one into a normal form", selection: "")
        check("maths rule: a plain algebra question gets it", asked.contains(.maths) && !asked.contains(.graphs))
        check("maths rule: so does a words-only maths question", Prompts.features(question: "how do I simplify this fraction", selection: "").contains(.maths))
        check("maths rule: a highlight in a Math sector gets it", Prompts.features(question: "what does this mean", selection: "the derivative of x squared is 2x").contains(.maths))
        check("maths rule: a non-maths question stays lean",
              !Prompts.features(question: "why did the Roman empire fall", selection: "The empire fell in 476 AD.").contains(.maths))
        check("maths rule: the prompt carries LaTeX only when asked for",
              Prompts.system(webSearch: false, features: .maths).contains("LaTeX") && !Prompts.system(webSearch: false, features: []).contains("LaTeX")
              && Prompts.system(webSearch: false, features: .graphs).contains("LaTeX"))
        let later = Prompts.extraInstructions(for: "how do I simplify x^(-3/2)", have: [])
        check("maths rule: a later maths question carries it along", later?.text.contains("LaTeX") == true && later?.added.contains(.maths) == true)
        check("maths rule: not repeated for a chat that has it", Prompts.extraInstructions(for: "simplify x^2", have: .maths) == nil
              && Prompts.extraInstructions(for: "simplify x^2", have: .graphs) == nil)
    }
}
