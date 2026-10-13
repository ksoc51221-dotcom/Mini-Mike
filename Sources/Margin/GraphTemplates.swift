import Foundation

/// Ready-made graphs for the pictures people ask for most (supply and demand, parabolas, lines, waves, tangents, growth, the
/// bell curve). With Local Mode on, a Visualize request that clearly fits one is drawn right here: no Claude call, no
/// tokens. The graph uses the same format Claude's graphs do, so it has the same sliders and hover. Anything that doesn't
/// clearly fit (or a follow-up) goes to Claude, and "Ask Claude" under the answer asks it for a custom one.
enum GraphTemplates {
    struct Template {
        let name: String
        /// Words that point to it (each distinct match counts).
        let keywords: [String]
        let intro: String
        let json: String
        let outro: String
    }

    /// The label under the answer ("Answered on your Mac · graph template").
    static let label = "graph template"

    // MARK: Choosing

    private static let wantsGraph = try! NSRegularExpression(
        pattern: #"\b(?:graphs?|plot|plots|chart|draw|diagrams?|visuali[sz]\w*|curves?|sketch|illustrate|sliders?|show me|picture)\b"#, options: [.caseInsensitive])

    static func isGraphRequest(_ prompt: String) -> Bool {
        prompt == Prompts.visualize || wantsGraph.firstMatch(in: prompt, range: NSRange(prompt.startIndex..., in: prompt)) != nil
    }

    private static func hits(_ keywords: [String], in text: String) -> Int {
        keywords.reduce(0) { n, k in
            n + (text.range(of: #"(?<![A-Za-z])(?:"# + k + #")(?![A-Za-z])"#, options: [.regularExpression, .caseInsensitive]) != nil ? 1 : 0)
        }
    }

    /// The template a request clearly fits, or nil. A word in the question counts double; a lone word in the highlight
    /// ("supply chain") isn't enough.
    static func match(prompt: String, selection: String) -> Template? {
        guard isGraphRequest(prompt) else { return nil }
        let picked = String(selection.prefix(3000))
        let scored = all.map { t in (t, 2 * hits(t.keywords, in: prompt) + min(3, hits(t.keywords, in: picked))) }
            .filter { $0.1 >= 2 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil } // can't tell: Claude can
        return best.0
    }

    /// The answer text, with the graph, as Claude would have written it.
    static func answer(_ t: Template) -> String { "\(t.intro)\n<graph>\(t.json)</graph>\n\(t.outro)" }

    // MARK: The templates

    static let all: [Template] = [
        Template(
            name: "Supply and demand",
            keywords: ["supply", "demand", "equilibrium", "shortage", "surplus", "market price", "consumer surplus", "producer surplus", "price ceiling", "price floor"],
            intro: "Here's the supply and demand model, ready to move.",
            json: #"{"title":"Supply and demand","x":{"label":"Quantity","min":0,"max":10,"numbers":false},"y":{"label":"Price","min":0,"max":10,"numbers":false},"sliders":[{"name":"dshift","label":"Demand shift","min":-2,"max":2,"value":0},{"name":"sshift","label":"Supply shift","min":-2,"max":2,"value":0}],"plots":[{"name":"D","y":"8-0.7*x+dshift","label":"D","color":"blue"},{"name":"S","y":"1+0.6*x+sshift","label":"S","color":"orange"}],"points":[{"name":"E","intersect":["D","S"],"label":"E","guides":["Q*","P*"]}],"areas":[{"between":["D","E.y"],"from":0,"to":"E.x","label":"CS"},{"between":["E.y","S"],"from":0,"to":"E.x","label":"PS"}],"caption":"Drag a shift slider and watch the equilibrium E move."}"#,
            outro: "Slide demand right and the price and quantity both rise; slide supply right and the price falls while the quantity rises."),
        Template(
            name: "Parabola",
            keywords: ["quadratic", "parabolas?", "vertex", "x\\^2", "x²", "roots", "discriminant", "axis of symmetry"],
            intro: "Here's a parabola you can reshape.",
            json: #"{"title":"y = a(x − h)² + k","x":{"min":-6,"max":6},"y":{"min":-5,"max":10},"sliders":[{"name":"a","label":"a","min":-2,"max":2,"value":1},{"name":"h","label":"h","min":-4,"max":4,"value":1},{"name":"k","label":"k","min":-4,"max":6,"value":-2}],"plots":[{"name":"f","y":"a*(x-h)^2+k","label":"f(x)"}],"points":[{"label":"vertex","x":"h","y":"k","guides":true}],"lines":[{"x":"h","label":"axis of symmetry"}],"caption":"Drag h and k to move the vertex; a stretches the parabola and flips it below zero."}"#,
            outro: "The vertex is at (h, k), and a decides whether it opens up or down."),
        Template(
            name: "Straight line",
            keywords: ["slope-intercept", "linear function", "linear equation", "straight line", "y ?= ?m ?x", "gradient", "y-intercept", "slope"],
            intro: "Here's a straight line you can tilt and slide.",
            json: #"{"title":"y = mx + b","x":{"min":-6,"max":6},"y":{"min":-8,"max":10},"sliders":[{"name":"m","label":"slope m","min":-3,"max":3,"value":1},{"name":"b","label":"intercept b","min":-4,"max":6,"value":2}],"plots":[{"name":"f","y":"m*x+b","label":"f(x)"}],"points":[{"label":"y-intercept","x":0,"y":"b","guides":true}],"caption":"m is how steep it is; b is where it crosses the y-axis."}"#,
            outro: "Every step right moves it up by m, starting from height b."),
        Template(
            name: "Wave",
            keywords: ["sine", "cosine", "sin\\(?x?\\)?", "cos\\(?x?\\)?", "amplitude", "period", "trigonometr\\w*", "waves?", "frequency"],
            intro: "Here's a sine wave you can stretch and shift.",
            json: #"{"title":"y = A sin(Bx + C)","x":{"min":-7,"max":7},"y":{"min":-4,"max":4},"sliders":[{"name":"A","label":"amplitude A","min":0.5,"max":3,"value":1},{"name":"B","label":"frequency B","min":0.5,"max":3,"value":1},{"name":"C","label":"shift C","min":-3,"max":3,"value":0}],"plots":[{"name":"f","y":"A*sin(B*x+C)","label":"f(x)"}],"lines":[{"y":"A","label":"amplitude"},{"y":0}],"caption":"A sets the height, B how often it repeats, C slides it sideways."}"#,
            outro: "The period is 2π divided by B."),
        Template(
            name: "Tangent line",
            keywords: ["derivatives?", "tangent lines?", "tangent", "instantaneous rate", "differentiat\\w*", "rate of change"],
            intro: "Here's a curve with its tangent line, so you can see what a derivative is.",
            json: #"{"title":"The tangent line is the slope at a point","x":{"min":-4,"max":4},"y":{"min":-2,"max":12},"sliders":[{"name":"a","label":"point x = a","min":-3,"max":3,"value":1}],"plots":[{"name":"f","y":"x^2","label":"f(x) = x²"}],"points":[{"on":"f","x":"a","label":"(a, f(a))","guides":true}],"lines":[{"tangent":"f","at":"a","label":"tangent"}],"caption":"Drag a: the tangent's slope is the derivative there (2a for x²)."}"#,
            outro: "The steeper the tangent, the faster the function is changing at that point."),
        Template(
            name: "Exponential",
            keywords: ["exponential", "compound interest", "decay", "half-life", "growth rate", "doubling"],
            intro: "Here's exponential growth and decay you can adjust.",
            json: #"{"title":"y = a·e^(kx)","x":{"min":-3,"max":5},"y":{"min":-1,"max":20},"sliders":[{"name":"a","label":"start a","min":0.2,"max":3,"value":1},{"name":"k","label":"rate k","min":-1,"max":1,"value":0.4}],"plots":[{"name":"f","y":"a*exp(k*x)","label":"f(x)"}],"lines":[{"y":0}],"caption":"A positive k grows faster and faster; a negative k decays toward zero."}"#,
            outro: "The rate k sets how quickly it grows or shrinks."),
        Template(
            name: "Bell curve",
            keywords: ["normal distribution", "bell curve", "standard deviation", "gaussian", "z-score", "mean and variance"],
            intro: "Here's the normal distribution, with sliders for its mean and spread.",
            json: #"{"title":"Normal distribution","x":{"min":-6,"max":6},"y":{"min":0,"max":0.9},"sliders":[{"name":"mu","label":"mean","min":-3,"max":3,"value":0},{"name":"s","label":"standard deviation","min":0.5,"max":2,"value":1}],"plots":[{"name":"f","y":"exp(-((x-mu)^2)/(2*s^2))/(s*sqrt(2*pi))","label":"density"}],"areas":[{"under":"f","from":"mu-s","to":"mu+s","label":"about 68%"}],"lines":[{"x":"mu","label":"mean"}],"caption":"A smaller standard deviation makes it taller and narrower; the shaded part is within one of the mean."}"#,
            outro: "About 68% of values fall within one standard deviation of the mean."),
    ]
}

/// An answer that needs no model: it hands over a ready-made graph at once. Anything else it's asked (a follow-up) it passes
/// back, so the chat moves to Claude.
final class TemplateSession: AnswerSession {
    var onEvent: ((ClaudeSession.Event) -> Void)?
    var onUsage: ((ClaudeSession.Usage) -> Void)?
    var isAlive: Bool { true }
    private let template: GraphTemplates.Template

    init(_ template: GraphTemplates.Template) { self.template = template }

    func start() throws {}

    func send(_ text: String, images: [Data]) {
        let t = template
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.sentFirst {
                self.onEvent?(.unavailable("The template doesn't cover that"))
                return
            }
            self.sentFirst = true
            self.onEvent?(.delta(GraphTemplates.answer(t)))
            self.onUsage?(ClaudeSession.Usage())
            self.onEvent?(.turnDone)
        }
    }

    private var sentFirst = false
    func stop() {}
}
