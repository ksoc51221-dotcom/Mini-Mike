import Foundation

extension FeatureTests {
    /// Speech hints: the Whisper prompt for Groq, and Claude's "may be misheard" rule.
    static func speechContextChecks(_ check: (String, Bool) -> Void) {
        var c = SpeechContext()
        check("speech: with nothing heard, Whisper gets only the name", c.whisperPrompt == "Merlin.")
        c.remember("   ", sentToGroq: true)
        check("speech: blank speech is not remembered", c.recent.isEmpty)
        c.remember("What is price elasticity of demand?", sentToGroq: false)
        check("speech: Apple's text is never kept, so never sent to Groq", c.recent.isEmpty && c.whisperPrompt == "Merlin.")
        c.remember("Tell me about Giffen goods.", sentToGroq: true)
        c.remember("And the Laffer curve?", sentToGroq: true)
        check("speech: Whisper prompt is the name, then what Groq heard, oldest first",
              c.whisperPrompt == "Merlin. Tell me about Giffen goods. And the Laffer curve?")

        var many = SpeechContext()
        for i in 1...5 { many.remember("press number \(i)", sentToGroq: true) }
        check("speech: only the last three presses are kept", many.recent == ["press number 3", "press number 4", "press number 5"])

        var long = SpeechContext()
        long.remember(String(repeating: "alpha ", count: 200) + "the newest omega words", sentToGroq: true)
        let lp = long.whisperPrompt
        check("speech: a long Whisper prompt is cut to the limit", lp.count <= SpeechContext.maxPromptCharacters)
        check("speech: the cut keeps the end and the name, with no half word",
              lp.hasSuffix("the newest omega words") && lp.hasPrefix("Merlin. alpha "))

        // Groq gets the prompt as its own form field; with no prompt (or an empty one), no field.
        let withPrompt = String(decoding: GroqTranscriber.multipartBody(wav: Data([1]), boundary: "B", prompt: "Merlin. hello"), as: UTF8.self)
        check("speech: Groq request carries the prompt field", withPrompt.contains("name=\"prompt\"\r\n\r\nMerlin. hello\r\n"))
        let noPrompt = String(decoding: GroqTranscriber.multipartBody(wav: Data([1]), boundary: "B"), as: UTF8.self)
        let blank = String(decoding: GroqTranscriber.multipartBody(wav: Data([1]), boundary: "B", prompt: ""), as: UTF8.self)
        check("speech: no prompt, or an empty one, sends no field", !noPrompt.contains("name=\"prompt\"") && !blank.contains("name=\"prompt\""))

        // Claude is told questions may be dictated, in every system prompt.
        check("speech: Claude's system prompt says words may be misheard",
              Prompts.system(webSearch: false).contains(Prompts.dictationRule)
              && Prompts.system(webSearch: true, features: []).contains(Prompts.dictationRule))

        // Claude's <heard> fix: read, never shown, held back while it streams in.
        let reply = "<heard>What are Giffen goods?</heard>\nThey are goods people buy more of as the price rises."
        check("heard: the corrected question is read", Answer.heard(in: reply) == "What are Giffen goods?")
        check("heard: no tag, no fix", Answer.heard(in: "Plain answer.") == nil && Answer.heard(in: "<heard> </heard>x") == nil)
        check("heard: the tag never reaches the shown answer",
              Answer.pieces(reply) == [.text("They are goods people buy more of as the price rises.")]
              && !Answer.plainText(reply).contains("heard") && !Answer.noteMarkup(reply).contains("heard"))
        check("heard: a tag with a meta line both come off",
              Answer.withoutMeta(reply + "\n<meta title=\"Giffen goods\" sector=\"Economics\"/>") == "They are goods people buy more of as the price rises.")
        check("heard: a half-written tag is hidden while streaming",
              Answer.pieces("<heard>What are Giff", hidePartial: true).isEmpty && Answer.pieces("<hea", hidePartial: true).isEmpty)

        // The fix is only taken when it is small.
        let raw = "What are giving goods and how do they link to the laugh occur?"
        check("fix: sound-alike words are fixed", DictationFix.accept(original: raw,
              corrected: "What are Giffen goods and how do they link to the Laffer curve?") == "What are Giffen goods and how do they link to the Laffer curve?")
        check("fix: a split word joined", DictationFix.accept(original: "explain elastic city", corrected: "explain elasticity") == "explain elasticity")
        check("fix: quotes around it are dropped", DictationFix.accept(original: "what are giving goods", corrected: "“what are Giffen goods”") == "what are Giffen goods")
        check("fix: no real change is no fix", DictationFix.accept(original: "What is GDP?", corrected: "what is gdp") == nil
              && DictationFix.accept(original: "What is GDP?", corrected: nil) == nil && DictationFix.accept(original: "x", corrected: "  ") == nil)
        check("fix: an answer instead of a fix is refused",
              DictationFix.accept(original: "what are giving goods", corrected: "Giffen goods are goods whose demand rises when their price rises, unusually.") == nil)
        check("fix: a rewrite is refused", DictationFix.accept(original: raw, corrected: "Explain the Laffer curve to me simply please now") == nil)
        check("fix: markup or many lines are refused", DictationFix.accept(original: "what is gdp", corrected: "what is <b>GDP</b>") == nil
              && DictationFix.accept(original: "what is gdp", corrected: "what is\nGDP") == nil)

        // In a chat: a spoken question takes the fix; a typed one never does; the screenshot note stays.
        func chat(_ spoken: Bool, _ answer: String, screenshot: Bool = false) -> AskModel.Turn? {
            let m = AskModel(selection: Selection(text: "x", appName: "Test", context: ContextBox(resolved: nil), pid: 0, mouse: .zero), footnote: "")
            m.instantText = true
            if screenshot { m.attachments = [.init(data: Data([1]), thumb: nil)] }
            m.ask(display: "what are giving goods", prompt: "what are giving goods", spoken: spoken)
            m.append(answer)
            m.finishTurn()
            return m.turns.last
        }
        let fixedTurn = chat(true, "<heard>what are Giffen goods</heard>Goods you buy more of as they cost more.")
        check("fix: a spoken question shows the fixed words and a clean answer",
              fixedTurn?.question == "what are Giffen goods" && fixedTurn?.answer == "Goods you buy more of as they cost more.")
        let typedTurn = chat(false, "<heard>what are Giffen goods</heard>Goods you buy more of.")
        check("fix: a typed question is never changed, but the tag still comes off",
              typedTurn?.question == "what are giving goods" && typedTurn?.answer == "Goods you buy more of.")
        let shotTurn = chat(true, "<heard>what are Giffen goods</heard>Goods.", screenshot: true)
        check("fix: the screenshot note stays after the fix", shotTurn?.question == "what are Giffen goods" + AskModel.screenshotSuffix)
        do { // web search: a tool starts after the <heard> line and wipes the text so far; the fix survives
            let m = AskModel(selection: Selection(text: "x", appName: "Test", context: ContextBox(resolved: nil), pid: 0, mouse: .zero), footnote: "")
            m.instantText = true
            m.ask(display: "what are giving goods", prompt: "what are giving goods", spoken: true)
            m.append("<heard>what are Giffen goods</heard>Let me check.")
            m.toolActivity("Searching the web…")
            m.append("Goods you buy more of as they cost more.")
            m.finishTurn()
            check("fix: the fix survives a web search", m.turns.last?.question == "what are Giffen goods"
                  && m.turns.last?.answer == "Goods you buy more of as they cost more.")
        }
        let refusedTurn = chat(true, "<heard>Tell me everything about the history of economics</heard>Sure.")
        check("fix: a refused fix keeps the spoken words", refusedTurn?.question == "what are giving goods" && refusedTurn?.answer == "Sure.")
        check("speech: the quick Claude model gets the rule too; a model on this Mac does not",
              Prompts.quickSystem(seeing: false, model: Settings.haikuID, features: []).contains(Prompts.dictationRule)
              && !Prompts.quickSystem(seeing: false, model: "qwen3:8b", features: []).contains(Prompts.dictationRule))
    }
}
