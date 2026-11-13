import Foundation

enum Prompts {
    /// The parts of the system prompt that are long and only sometimes needed. Leaving out the ones a question won't
    /// use is the biggest single saving on what each chat costs (about 1,500 tokens of a 2,700-token prompt).
    struct Features: OptionSet {
        let rawValue: Int
        static let voice = Features(rawValue: 1)
        static let graphs = Features(rawValue: 2)
        /// Just the short rule that makes equations come out typeset (LaTeX). Graph chats get it too.
        static let maths = Features(rawValue: 4)
        static let all: Features = [.voice, .graphs, .maths]
    }

    static func system(webSearch: Bool, sectors: [String] = Sector.defaults, sectorHints: [String: String] = [:], features: Features = .all) -> String {
        var rules = [
            "Answer only what they asked, in 2-4 short plain-language sentences (aim for under ~80 words) unless they ask for more.",
            "Use the screenshot and surrounding text to figure out what \"this\", \"it\", or a term refers to. Ignore unrelated things on screen and never describe the screenshot back to them.",
            "Sometimes they can't highlight text (a scanned PDF, an image, a diagram), so instead they snip the area they're asking about and send it as an image. Treat that snip exactly like highlighted text.",
        ]
        if webSearch {
            rules += [
                "Accuracy matters more than speed. If the answer depends on specific facts, versions, numbers, names, recent events, or anything you aren't sure about, use web search to check before answering. Skip searching for simple concept explanations you're confident about.",
                "Don't narrate what you're doing (no \"Let me search…\"). Just give the answer.",
                "When you used the web, end with \"Sources:\" followed by 1-3 markdown links.",
            ]
        }
        if features.contains(.voice) { rules.append(sayRule) }
        if features.contains(.graphs) { rules.append(Prompts.graphs) }
        if features.contains(.graphs) || features.contains(.maths) { rules.append(mathsRule) }
        rules += [
            "Add one tiny concrete example only if it genuinely makes it click.",
            "No headers, no long bullet lists, no preamble, and don't restate or summarize the passage back to them.",
            "If they ask you to go deeper, give a fuller explanation (up to ~200 words), still in plain language.",
            "Follow-up questions refer to the same highlighted text and your earlier answers.",
            metaRule(sectors, hints: sectorHints),
        ]
        return """
        You are Margin, a quick clarifier that lives next to the user's cursor. The user highlighted a bit of \
        text (often from an explanation Claude gave them in another chat) and is confused about one part of it. \
        You get the highlighted text, sometimes the text around it, often a screenshot of their screen at the \
        moment they asked, and their question.

        How to answer:
        \(rules.map { "- " + $0 }.joined(separator: "\n"))
        """
    }

    // MARK: Context and Rules

    /// How much of each box is sent. The boxes go in every chat's system prompt, so a huge paste can't quietly get expensive.
    static let maxPersonal = 4000
    /// Where the boxes are read from. Tests swap in a throwaway store.
    static var personalSource = Settings.shared

    /// The Context and Rules text for a system prompt, or "" when both are empty.
    static func personalBlock(context: String, rules: String) -> String {
        let about = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let must = rules.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if !about.isEmpty {
            parts.append("What the user has told you about themselves. Use it when it helps, and don't recite it back:\n" + clip(about, maxPersonal))
        }
        if !must.isEmpty {
            parts.append("The user's rules. Follow them in every answer, even where they differ from the guidance above:\n" + clip(must, maxPersonal))
        }
        return parts.joined(separator: "\n\n")
    }

    /// A chat's system prompt with the user's Context and Rules added. This is set once when a chat starts, so follow-ups
    /// don't resend it. With both boxes empty, `base` comes back exactly as it went in.
    static func personalized(_ base: String, settings: Settings? = nil) -> String {
        let source = settings ?? personalSource
        let block = personalBlock(context: source.personalContext, rules: source.personalRules)
        return block.isEmpty ? base : base + "\n\n" + block
    }

    // MARK: Learn mode

    static let hintLevels = 1...4
    /// The picker's short names.
    static func hintName(_ level: Int) -> String {
        switch level {
        case 1: return "Bare hint"
        case 2: return "The method"
        case 3: return "Most of it"
        default: return "Full working"
        }
    }

    /// Working is long; it should still be easy to take in: a headline, short numbered steps, room to breathe.
    private static let digestible = "Make it easy to take in, not shorter: open with one bold line saying the approach, then numbered steps with one idea each (a bold few-word name for the step, then at most two short sentences), a blank line between steps, and each line of working on its own line. No walls of text."

    private static func hintInstruction(_ level: Int) -> String {
        switch level {
        case 1: return "give the bare minimum nudge: one short sentence on where to look or what to think about. Don't name the method, do any working or give the answer."
        case 2: return "name the idea or method that applies and why it fits, in one or two sentences. Don't do any working or give the answer."
        case 3: return "walk me through the working up to the last step, and leave that last step for me. Don't give the final answer. " + digestible + " End with one line starting \"Your turn:\" that points at the last step."
        default: return "give the full working step by step, with the final answer. Ignore the usual length limit for this. " + digestible + " End with the final answer in bold on its own line."
        }
    }

    /// The chat's question line for a hint.
    static func hintLabel(_ level: Int, question: String? = nil) -> String {
        let label = "Hint level \(level)"
        return question.map { "\($0) · \(label.lowercased())" } ?? label
    }

    /// What's asked at a hint level. `question` is one they typed (otherwise the highlight or snip is the question);
    /// `movingUp` is the same problem at a higher level, from the button under an answer.
    static func hint(_ level: Int, question: String? = nil, movingUp: Bool = false) -> String {
        let opening: String
        if movingUp { opening = "Same problem, more help." }
        else if let question { opening = question + "\n\nI'm working this out myself." }
        else { opening = "What I highlighted or snipped is the problem I'm working on." }
        return opening + " Hint level \(level) of 4: " + hintInstruction(level)
            + (level < 4 ? " Keep to this level of help in any follow-up until I ask for more." : "")
    }

    /// How Claude speaks: <say> clips that Margin turns into voice messages. Only sent when it is likely to be used.
    static let sayRule = """
    You can speak. When they ask how to pronounce something, or ask you to say it, include a voice clip \
    for each word or short phrase: <say lang="ru-RU" ipa="zɐˈmok">замо́к</say>. The app turns every tag into \
    a playable voice message read by a native voice. Use the right BCP-47 language code. For Russian and \
    Ukrainian, put an acute accent (U+0301) on the stressed vowel in the visible text. Always give accurate IPA \
    in `ipa`, with ˈ before the stressed syllable and one IPA word per word for phrases: the voice follows your \
    IPA, so you decide the stress; write it as a native actually says it (reduced vowels, silent letters dropped, \
    voicing assimilation), so it agrees with what you explain, and check that each word's ˈ sits on the same \
    syllable as its accent mark. For a whole sentence, use one clip for the full sentence so they hear its \
    natural rhythm (its ipa has one IPA word per spoken word, no punctuation), then optional separate clips for \
    1-3 tricky words. Then add a sentence or two on what's tricky (stress, vowel reduction, soft consonants) and \
    a rough English sound-alike. Never put <say> tags inside code blocks, and don't search the web for \
    pronunciation.
    """

    /// Equations as LaTeX, which Margin typesets. Without this the model writes x^(-3/2) as plain text.
    static let mathsRule = "Write maths as LaTeX that Margin typesets: $…$ for a symbol or short expression inside a sentence (like $v_y$, $\\theta$, $\\sqrt{2}$, $x^{-3/2}$), and $$…$$ on its own line for each key equation (like $$x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}$$). Even a simple fraction or power goes in $…$. Write money as plain \\$5 or \"5 dollars\", never inside $…$. Everything else stays plain text."

    private static func regex(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let voiceWords = regex(#"\b(?:pronounc\w*|say (?:it|this|that|these)|how (?:do|would|to) (?:you |i )?say|out loud|aloud|accent|ipa|stress(?:ed)?|sounds? like|read (?:it|this|that) (?:out|aloud))\b"#)
    /// Maths in the question or highlight: carets, roots, number fractions, "2x", or maths words.
    private static let mathSymbols = regex(#"\^|√|∫|∑|π|≤|≥|\d\s*/\s*\d|\b\d+[a-z]\b|\b[a-z]\s*=\s*[-\d(]"#)
    private static let mathWords = regex(#"\b(?:solve|simplify|factor(?:ise|ize|ing)?|expand|integra\w*|differentiat\w*|derivatives?|equations?|formulas?|fractions?|exponents?|powers?|roots?|logs?|logarithms?|sin|cos|tan|lim|limits? (?:as|of)|matrix|matrices|proof|prove|theorem|algebra|calculus|calculate|compute|quadratic|polynomials?|inequalit\w*|radicals?|surds?|velocity|acceleration|energy|normal form|standard form)\b"#)
    private static let graphWords = regex(#"\b(?:graphs?|plot|plots|chart|charts|draw|diagrams?|visuali[sz]\w*|curves?|sketch|illustrate|sliders?|show me|picture this|supply|demand|equilibrium|parabolas?|quadratic|derivative|tangent|vertex|slope|function|equation|probability|distribution|vector|trigonometr\w*|sine|cosine|elasticity)\b"#)

    /// Which long prompt sections this question is likely to need, decided on this Mac from the words used and the highlight.
    static func features(question: String, selection: String, context: String? = nil) -> Features {
        func has(_ r: NSRegularExpression, _ t: String) -> Bool { r.firstMatch(in: t, range: NSRange(location: 0, length: (t as NSString).length)) != nil }
        var out: Features = []
        let text = question + " " + selection
        if question == pronounce || has(voiceWords, question) || Router.nonLatinLetterCount(text + " " + (context ?? "")) >= 3
            || Sector.guess(from: selection) == "Language" { out.insert(.voice) }
        if question == visualize || has(graphWords, question)
            || ["Math", "Economics", "Physics"].contains(Sector.guess(from: selection) ?? "") { out.insert(.graphs) }
        if has(mathSymbols, text) || has(mathWords, text)
            || ["Math", "Economics", "Physics", "Chemistry"].contains(Sector.guess(from: selection) ?? "") { out.insert(.maths) }
        return out
    }

    /// A section the chat's prompt left out but a later question needs: sent with that question instead.
    static func extraInstructions(for question: String, have: Features) -> (text: String, added: Features)? {
        var needed = features(question: question, selection: "").subtracting(have)
        if have.contains(.graphs) { needed.remove(.maths) } // a graph chat's prompt already has the maths rule
        guard !needed.isEmpty else { return nil }
        var parts: [String] = []
        if needed.contains(.voice) { parts.append(sayRule) }
        if needed.contains(.graphs) { parts.append(graphs) }
        if needed.contains(.maths) { parts.append(mathsRule) }
        return ("Extra instructions for this answer:\n" + parts.joined(separator: "\n\n"), needed)
    }

    /// How Claude draws: a <graph> with JSON that Margin renders itself (see GraphSpec), so curves are exact.
    static let graphs = """
    You can draw. When a picture would make it click faster (a function's shape, what changing a value does,     slopes and rates, areas, probability, supply and demand and other economics curves, motion, geometry,     a process or cycle), add ONE <graph>…</graph> with JSON inside, then 1-3 sentences on what to notice.     Always draw when they ask for a graph, diagram, chart or visual; skip it for simple facts, definitions and     pronunciation. If they're asking about a graph on their screen, redraw it with the key idea marked.     Margin computes every curve from your formulas, so they come out exact. Never put the tag in a code block.
    JSON (use only what helps):
    - "title"; "caption": one short line on what to notice or try.
    - "x", "y": {"label", "min", "max", "numbers": false to hide tick numbers, as in economics diagrams}.
    - "sliders": [{"name", "label", "min", "max", "value"}]: 1-3 values to drag for "what happens if…"     (shift a curve, change a, h, k). Use their names in expressions.
    - "plots": [{"name", "label", "y": "expression in x"}], or {"points": [[x,y],…], "smooth": true}, or     {"parametric": ["x(t)", "y(t)"], "t": [0, "2*pi"]}. Optional "color" (blue, orange, green, purple, red,     pink, teal, gray), "dashed": true, "from"/"to" to limit x.
    - "points": [{"name", "label", "x", "y"}], or {"intersect": ["D", "S"]} (add "all": true for every     crossing, e.g. ["f", "0"] for roots), or {"on": "f", "x": "a"}. "guides": true (or ["Q*", "P*"]) drops dashed     lines to the axes; "hollow": true for an open circle.
    - "lines": [{"x": …} or {"y": …} (dashed reference lines), {"tangent": "f", "at": …},     {"through": [[x1,y1],[x2,y2]]}], each with an optional "label".
    - "areas": [{"between": ["D", "E.y"], "from": 0, "to": "E.x", "label": "CS"}] (each side is a plot's name or     an expression), or {"under": "f", "from": a, "to": b}.
    - "shapes" for diagrams, vectors and geometry: {"arrow": [[x1,y1],[x2,y2]], "label"}, {"segment": …},     {"polygon": [[x,y],…]}, {"circle": [cx, cy, r]}, {"box": [cx, cy, w, h], "label"}, {"text": "…", "at": [x,y]}.     Add "axes": false for a pure diagram, "equal": true to keep circles round.
    Expressions: x, numbers, + - * / ^, parentheses, sqrt abs sin cos tan exp ln log (base 10) min max,     if(cond, a, b), pi, e, slider names, plots called like f(2), and point coordinates like E.x.     Write multiplication with * (a*x^2, not ax^2). Keep it to one graph unless comparing two is the point.
    Examples:
    <graph>{"title":"y = a(x − h)² + k","x":{"min":-6,"max":6},"y":{"min":-5,"max":10},    "sliders":[{"name":"a","min":-2,"max":2,"value":1},{"name":"h","min":-4,"max":4,"value":1},    {"name":"k","min":-4,"max":6,"value":-2}],"plots":[{"name":"f","y":"a*(x-h)^2+k","label":"f(x)"}],    "points":[{"label":"vertex","x":"h","y":"k","guides":true}],"lines":[{"x":"h","label":"axis of symmetry"}],    "caption":"Drag h and k to move the vertex; a stretches the parabola and flips it below zero."}</graph>
    <graph>{"title":"Supply and demand","x":{"label":"Quantity","min":0,"max":10,"numbers":false},    "y":{"label":"Price","min":0,"max":10,"numbers":false},    "sliders":[{"name":"shift","label":"Demand shift","min":-2,"max":2,"value":0}],    "plots":[{"name":"D","y":"8-0.7*x+shift","label":"D","color":"blue"},    {"name":"S","y":"1+0.6*x","label":"S","color":"orange"}],    "points":[{"name":"E","intersect":["D","S"],"label":"E","guides":["Q*","P*"]}],    "areas":[{"between":["D","E.y"],"from":0,"to":"E.x","label":"CS"},    {"between":["E.y","S"],"from":0,"to":"E.x","label":"PS"}]}</graph>
    """

    /// How Claude names and files a chat without an extra call: one hidden line at the end of its first answer.
    static func metaRule(_ sectors: [String], hints: [String: String] = [:]) -> String {
        let described = sectors.filter { !(hints[$0] ?? "").isEmpty }
        let guide = described.isEmpty ? "" : " Sector guide: "
            + described.map { "\($0) = \(String((hints[$0] ?? "").prefix(90)))" }.joined(separator: "; ") + "."
        return "In your FIRST answer of a chat only, finish with one extra line that names and files the chat: "
            + "<meta title=\"a 3-6 word title\" sector=\"Math\"/>. The sector is one of: "
            + sectors.joined(separator: ", ")
            + " (or one new short sector name only if none of them fits)." + guide + " Never write it in later answers."
    }

    static let quizLabel = "Quiz me"
    /// Asks for a quiz on what was just explained, as a <quiz> Margin shows and grades itself.
    static let quiz = """
        Quiz me on what you've just explained (use my highlighted text and your answers). Reply with ONLY one \
        <quiz>…</quiz> holding JSON, with no other text: \
        {"title": "short title", "questions": [{"q": "…", "options": ["…","…","…","…"], "answer": 0, "why": "…"}, …, \
        {"q": "…", "answer": "the model answer in one or two sentences", "why": "…"}]}. \
        Write 4 questions: 3 multiple choice with 4 plausible options each ("answer" is the right option's index from 0), \
        then 1 short-answer question with no options. Keep each question under 25 words, and each "why" to one short sentence.
        """

    static let deeper = "Go deeper on that — a fuller explanation, still plain language."

    static let visualize = "Show this as a graph or visual model, then tell me what to notice."
    static let pronounce = "How do I pronounce this? Say it for me."

    /// Quick-ask chips shown before the first question: (label, prompt).
    static let chips: [(label: String, prompt: String)] = [
        ("Simpler", "Explain this more simply."),
        ("Example?", "Give me a concrete example of what this means."),
        ("Define terms", "Define the jargon or technical terms in this, briefly."),
        ("Visualize", visualize),
        ("Pronounce", pronounce),
    ]

    /// The system prompt for a model running on this Mac (Local mode). It's Margin's plain clarifier: no voice
    /// clips, graphs or screenshot rules (the small model can't do those well; Claude does them), and it owns
    /// up to what it can't check instead of guessing.
    /// The on-Mac model summarizing a video from its transcript (or from notes condensed from it).
    static let localVideoSystem = """
        You write structured summaries of video transcripts for Margin. Follow the requested structure and headings exactly, in \
        plain Markdown. Use only what the transcript or notes say: never invent names, numbers, quotes or timestamps. Be concise.
        """

    static let localSystem = """
        You are Margin, a quick clarifier that lives next to the user's cursor. The user highlighted a bit of \
        text (often from an explanation Claude gave them in another chat) and is confused about one part of it. \
        You get the highlighted text, sometimes the text around it, and their question.

        How to answer:
        - Answer only what they asked, in 2-4 short plain-language sentences (aim for under ~80 words) unless they ask for more.
        - Add one tiny concrete example only if it genuinely makes it click.
        - No headers, no long bullet lists, no preamble, and don't restate or summarize the passage back to them.
        - If they ask you to go deeper, give a fuller explanation (up to ~200 words), still in plain language.
        - Follow-up questions refer to the same highlighted text and your earlier answers.
        - You can't search the web or see their screen. Only if the question truly depends on recent facts, exact \
        numbers or versions, or something you can't see, say so in one short sentence instead of guessing.
        """

    /// For a quick model that can look at pictures (Haiku): the same, but it may be sent a snip or a screenshot.
    static let localSystemSeeing = localSystem.replacingOccurrences(
        of: "You can't search the web or see their screen. Only if the question truly depends on recent facts, exact numbers or versions, or something you can't see, say so in one short sentence instead of guessing.",
        with: "You may be sent a snip or a screenshot of their screen: look at it when the question is about it. You can't search the web: only if the question truly depends on recent facts, exact numbers or versions, say so in one short sentence instead of guessing.")

    static let emptySubmit = "Explain this more simply."
    /// Sent when you add a screenshot and press return without typing.
    static let aboutScreenshot = "What's in the screenshot I added? Explain what matters in it."

    // MARK: Whole page / PDF

    static let docSummary = "Summarize this whole document: the main idea in two or three sentences, then the key points as short bullets."
    static let docTerms = "List the 6-10 key terms and concepts in this document, most important first, each with a one-line explanation."
    static func isDocOverview(_ prompt: String) -> Bool { prompt == docSummary || prompt == docTerms }

    /// The instructions that go with passages from a document: answer from them, cite pages, don't guess.
    private static let docRule = "Answer from the parts of the document below (page numbers in brackets) and cite pages like (p. 45). "
        + "If they don't cover the question, say so in one sentence instead of guessing."

    /// The first message of a chat about a whole page or document: only the passages that matter, never the document.
    static func firstWithDocument(app: String, doc: DocIndex, selection: String, passages: [Passage], question: String,
                                  overview: Bool) -> String {
        var parts = ["App: \(app)"]
        var about = "I'm reading «\(doc.title)» (\(doc.kind)" + (doc.pageCount.map { ", \($0) pages" } ?? "") + ")."
        if let note = doc.note { about += " (\(note).)" }
        parts.append(about)
        if !selection.isEmpty { parts.append("Highlighted: «\(clip(selection, maxSelection))»") }
        parts.append(overview
            ? "These excerpts are spread evenly through it, so base your answer on them and say it's from excerpts. " + docRule
            : "Here are the parts of it most relevant to my question. " + docRule)
        parts.append(DocIndex.render(passages))
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    /// A follow-up in a document chat: the passages for this question, then the question.
    static func withPassages(_ question: String, _ passages: [Passage], overview: Bool) -> String {
        guard !passages.isEmpty else { return question }
        return (overview ? "Excerpts spread through the document:\n\n" : "Parts of the document relevant to this:\n\n")
            + DocIndex.render(passages) + "\n\nQuestion: " + question
    }

    static let maxSelection = 4000
    /// Summaries are usually of long passages, so they get more of the highlighted text.
    static let maxSummarySelection = 20000

    /// The two ways to summarize, offered after you tap Summarize.
    enum Summary: CaseIterable {
        case meaning, keywords

        var title: String { self == .meaning ? "Overall meaning" : "Keywords & concepts" }
        var symbol: String { self == .meaning ? "text.alignleft" : "tag" }
        /// The question line shown in the chat.
        var display: String { "Summarize: " + (self == .meaning ? "overall meaning" : "keywords & concepts") }
        var prompt: String {
            switch self {
            case .meaning:
                return "Summarize the overall meaning of this in plain language. Start with the main point in one or two "
                    + "sentences, then add up to three short points that support it. Skip minor details."
            case .keywords:
                return "Summarize this as its keywords and concepts: the 4-8 most important terms or ideas, most important "
                    + "first, each on its own line as \"- **term**: what it means here\" in one short line."
            }
        }
    }

    static func isSummary(_ prompt: String) -> Bool { Summary.allCases.contains { $0.prompt == prompt } }
    static let maxContext = 1800

    /// `earlier` is for a chat moving to Claude from another model: the questions already asked and the answers
    /// given, so Claude can pick the conversation up where it was.
    static func first(app: String, selection: String, context: String?, question: String,
                      hasScreenshot: Bool = false, hasSnip: Bool = false, selectionLimit: Int = maxSelection,
                      earlier: [(question: String, answer: String)] = []) -> String {
        var parts = ["App: \(app)"]
        if hasSnip {
            parts.append("I couldn't highlight this as text, so I snipped the area I'm asking about. It's the first attached image.")
            if hasScreenshot {
                parts.append("(The second image is my whole screen at that moment, for context.)")
            }
        } else if selection.isEmpty {
            parts.append("Nothing is highlighted: I opened you with the keyboard shortcut to ask about whatever I'm doing.")
            if hasScreenshot {
                parts.append("(A screenshot of my screen at that moment is attached.)")
            }
        } else {
            parts.append("Highlighted: «\(clip(selection, selectionLimit))»")
            if let context, !context.isEmpty {
                parts.append("Surrounding text: «\(clip(context, maxContext))»")
            }
            if hasScreenshot {
                parts.append("(A screenshot of my screen at the moment I asked is attached.)")
            }
        }
        if !earlier.isEmpty {
            let lines = earlier.map { "Q: \(clip($0.question, 300))\nA: \(clip($0.answer, 900))" }
            parts.append("Earlier in this chat (answered without web search or a screenshot, so double-check anything "
                + "you build on):\n\n" + lines.joined(separator: "\n\n"))
        }
        parts.append("Question: \(question)")
        return parts.joined(separator: "\n\n")
    }

    // MARK: Video summaries

    /// The first message for a video agent: what it is, then the whole transcript, then the request.
    static func video(_ t: VideoTranscript, link: String?, request: String) -> String {
        var head = ["Video: \(t.title)"]
        if let channel = t.channel { head.append("Channel: \(channel)") }
        if let duration = t.duration { head.append("Length: \(VideoTranscript.clock(duration))") }
        head.append("Spoken language: \(t.languageName)")
        if let link { head.append("Link: \(link)") }
        head.append("Transcript source: \(t.origin)")
        return head.joined(separator: "\n") + "\n\nTranscript:\n" + t.formatted() + "\n\n" + request
    }

    /// How a timestamp is asked for: a link that opens the video at that moment, or (no link) just the time in brackets.
    static func stampPhrase(link: String?) -> String {
        link.map { "a markdown link to that moment, like [4:05](\($0)?t=245)" } ?? "the time in brackets, like [4:05]"
    }

    static func videoRequest(_ style: SummaryStyle, language: String, link: String?) -> String {
        let stamp = stampPhrase(link: link)
        var parts = ["""
        Summarize this video for me. This is a summary request, so ignore the usual short-answer limit. You decide the \
        shape: first work out what kind of video it is (a tutorial, lecture, interview or podcast, talk, news or commentary, \
        review, vlog, story, entertainment, or something else), then write the summary a smart friend would give me for \
        THAT kind of video, not a fixed template.

        - Open with one or two plain sentences: what this is and the bottom line (the answer, verdict, thesis or point).
        - Then give only what's worth keeping, in the form that fits. A tutorial gets the steps in order, with the exact \
        commands, settings or numbers. A lecture or talk gets the argument and its key ideas. An interview or podcast gets \
        who said what that matters, and the surprising claims. A review gets the verdict, pros, cons and who it's for. \
        Commentary or news gets the claims, and what's fact and what's opinion. Entertainment or a story gets what happens \
        and what made it worth watching.
        - Mark the moments worth jumping to with \(stamp), in bold or at the start of a line. Skip timestamps if the \
        video has no real sections.
        - Use short headings or bullets only where they help me scan, and no headings at all if a few sentences say it. \
        No emojis, no filler, no "in this video". Never pad: scale the length to the video (a few sentences for a few \
        minutes, up to about 400 words for an hour or more).
        - Keep specifics: names, numbers, quotes, tools and sources the video actually gives. Don't invent anything.

        Base it only on the transcript. Only if the captions are clearly garbled somewhere, say so in one line; otherwise don't mention caption quality. Don't search the web.
        """]
        switch style {
        case .english:
            parts.append("Write it in English.")
        case .englishWithPhrases:
            parts.append("""
            Write the summary in English. Then add **Useful \(language) phrases:** 5-8 words or short phrases from \
            the video worth learning, each as a <say> clip (with IPA and stress marks), then "— English meaning" and \
            its timestamp.
            """)
        case .practice:
            parts.append("""
            Write the whole summary in simple \(language) (around B1 level, short sentences) so I can practice \
            reading. Mark stress on Russian words, and put a short English gloss in parentheses after hard words. \
            End with **Useful phrases:** 5 key phrases from the video as <say> clips with English meanings.
            """)
        }
        return parts.joined(separator: "\n\n")
    }

    static func clip(_ s: String, _ limit: Int) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }
}
