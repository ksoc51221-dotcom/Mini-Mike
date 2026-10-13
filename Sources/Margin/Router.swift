import Foundation

/// Decides who answers a question: Claude, or (when Local mode is on) a model running on this Mac.
/// Pure functions only, so the whole policy can be unit-tested.
///
/// The policy, in one place:
/// - Claude always answers: videos, snips, blank chats (they need the screenshot), pronunciation, graphs,
///   anything about facts that change or need checking, anything about the screen, and any text that is
///   mostly not in the Latin alphabet (the small local model gets Russian stress and the like wrong).
/// - A *lean* Claude call (no screenshot, no web tools) is enough for Pronounce, Visualize and Summarize on
///   highlighted text: they never use either, and dropping them roughly halves what each call costs.
/// - The local model answers the quick questions (Simpler, Example?, Define terms, typed ones) and short
///   summaries, but only when Local mode is on and Ollama is up.
enum Router {
    struct Plan: Equatable {
        enum Engine: Equatable { case claude, local }
        var engine: Engine
        /// Claude only: no whole-screen screenshot and no web tools for this chat.
        var lean: Bool
        /// Why, in a few words (for tests and the log).
        var why: String

        var isLocal: Bool { engine == .local }
    }

    struct Input {
        var prompt: String
        var selection: String
        /// Text around the highlight (only checked for language).
        var context: String? = nil
        var hasSnip = false
        var isBlank = false
        var isVideo = false
        /// The chat is reading a whole page or document: the passages are sent, so no screenshot or web is needed.
        var hasDocument = false
        var localMode = false
        /// Ollama looks reachable and has the model (or hasn't been checked yet).
        var localUsable = true
        /// Screen Context is "Smart": a highlight is enough for most questions, so the screenshot and web tools stay out unless asked for.
        var smart = false
    }

    /// Longest highlight sent to the local model for a quick question (the most Claude would read, too).
    static let maxLocalSelection = Prompts.maxSelection
    /// Longest highlight the local model summarizes (as much as Claude is sent). For a summary with complex data that
    /// needs real analysis, ⌃⇧L moves that one chat to Claude.
    static let maxLocalSummary = Prompts.maxSummarySelection
    /// This many letters in another script (Cyrillic, Chinese, Arabic…) and the chat goes to Claude.
    static let nonLatinLimit = 3

    static func plan(_ i: Input) -> Plan {
        if i.isVideo { return Plan(engine: .claude, lean: false, why: "video") }
        let chipLean = i.prompt == Prompts.pronounce || i.prompt == Prompts.visualize || i.prompt == Prompts.quiz
            || Prompts.isSummary(i.prompt)
        if i.hasDocument { return Plan(engine: .claude, lean: true, why: "document") }
        if i.hasSnip { return Plan(engine: .claude, lean: chipLean, why: "snip") }
        if i.isBlank { return Plan(engine: .claude, lean: false, why: "nothing highlighted: needs the screenshot") }

        if i.prompt == Prompts.pronounce { return Plan(engine: .claude, lean: true, why: "pronunciation") }
        if i.prompt == Prompts.visualize { return Plan(engine: .claude, lean: true, why: "graphs") }
        if i.prompt == Prompts.quiz { return Plan(engine: .claude, lean: true, why: "quiz") }

        let localOK = i.localMode && i.localUsable
        let latin = nonLatinLetterCount(i.selection) + nonLatinLetterCount(i.context ?? "") + nonLatinLetterCount(i.prompt) < nonLatinLimit

        if Prompts.isSummary(i.prompt) {
            if localOK, latin, i.selection.count <= maxLocalSummary { return Plan(engine: .local, lean: false, why: "summary") }
            return Plan(engine: .claude, lean: true, why: i.selection.count > maxLocalSummary ? "long summary" : "summary")
        }

        if localOK, latin, i.selection.count <= maxLocalSelection, !needsClaude(i.prompt) {
            return Plan(engine: .local, lean: false, why: "quick question")
        }
        if i.smart, !i.selection.isEmpty, !needsScreen(i.prompt), !needsWeb(i.prompt) {
            return Plan(engine: .claude, lean: true, why: "the highlight is enough")
        }
        return Plan(engine: .claude, lean: false, why: !localOK ? "local mode off" : !latin ? "non-Latin text"
                    : i.selection.count > maxLocalSelection ? "long highlight" : "needs Claude")
    }

    /// A follow-up in a chat that already has an engine: does it need more than that engine has?
    /// A local chat moves to Claude for anything Claude-only; a lean Claude chat moves to a full one when the
    /// follow-up needs the web or the screen.
    static func needsEscalation(_ prompt: String, from plan: Plan) -> Bool {
        switch plan.engine {
        case .local: return needsClaude(prompt)
        case .claude: return plan.lean && (needsWeb(prompt) || needsScreen(prompt))
        }
    }

    /// Whether Margin should warm up the local model when a chat opens (it can only be used for a text highlight).
    static func mayGoLocal(selection: String, hasSnip: Bool, isVideo: Bool, localMode: Bool) -> Bool {
        localMode && !hasSnip && !isVideo && !selection.isEmpty && selection.count <= maxLocalSelection
            && nonLatinLetterCount(selection) < nonLatinLimit
    }

    // MARK: - What only Claude can do

    static func needsClaude(_ prompt: String) -> Bool {
        prompt == Prompts.quiz || needsWeb(prompt) || needsScreen(prompt) || needsSkill(prompt)
    }

    /// Facts that change, or that should be checked: the local model has no web and may guess.
    static func needsWeb(_ prompt: String) -> Bool { webWords.matches(prompt) }

    /// Questions about what's on the screen: only Claude gets the screenshot.
    static func needsScreen(_ prompt: String) -> Bool { screenWords.matches(prompt) }

    /// Things the local model does badly: saying words aloud, translating, drawing, working things out.
    static func needsSkill(_ prompt: String) -> Bool { skillWords.matches(prompt) }

    private static let webWords = Words(#"""
        \b(?:latest|newest|current|currently|recent|recently|news|today|tonight|yesterday|this (?:week|month|year)
        |re-?check|check
        |20(?:2[4-9]|[3-9]\d)|prices?|pricing|versions?|release date|stock|weather|search|look ?up|google|cites?
        |citations?|verify|fact[- ]?check|double[- ]?check|accurate|accuracy|up[- ]to[- ]date|outdated|reliable
        |trustworthy|is (?:it|this|that) (?:true|correct|right|real))\b
        |\b(?<!open[- ])sources?\b(?!\s+(?:code|files?|control|maps?|of truth))
        """#)

    private static let screenWords = Words(#"""
        \b(?:screenshot|my screen|the screen|on screen|on-screen|this screen
        |this (?:button|icon|menu|tab|window|image|picture|photo|page|site|website|app)
        |in the (?:image|picture|photo|screenshot))\b
        """#)

    private static let skillWords = Words(#"""
        \b(?:pronounc\w*|say (?:it|this|that) (?:for me|slowly|again|aloud|out)|how (?:do|to|would) (?:you |i )?say
        |out loud|aloud|accent|ipa
        |translat\w*|russian|ukrainian|graphs?|plots?|charts?|draw|diagrams?|visuali[sz]\w*|sketch
        |solve|calculate|compute|prove)\b
        """#)

    /// A case-insensitive pattern, compiled once. Line breaks and indentation in the source are ignored.
    private struct Words {
        let regex: NSRegularExpression

        init(_ pattern: String) {
            let flat = pattern.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined()
            regex = try! NSRegularExpression(pattern: flat, options: [.caseInsensitive])
        }

        func matches(_ text: String) -> Bool {
            regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
        }
    }

    // MARK: - Language

    /// How many letters are in a script other than Latin (Greek and math letters don't count: they're ordinary
    /// in the formulas the local model handles fine).
    static func nonLatinLetterCount(_ text: String) -> Int {
        var n = 0
        for u in text.unicodeScalars where u.value >= 0x370 && u.properties.isAlphabetic {
            let v = u.value
            if v <= 0x3FF || (0x1E00...0x1EFF).contains(v) || (0x2100...0x214F).contains(v) || (0x1D400...0x1D7FF).contains(v) {
                continue
            }
            n += 1
        }
        return n
    }
}
