import AppKit

// Messages to people: Apple Messages (iMessage) by AppleScript. Each send shows Merlin's own yes dialog first (who and
// all of the text; "Don't send" is the default), every time. The values go to AppleScript as arguments, never as script
// text. The recipient is a phone number or an email address from the user's words; a name alone isn't resolved (that
// would need Contacts access), so Claude asks for the number. macOS asks the user once to let Merlin control Messages.

struct MessagesBackend {
    /// Sends one iMessage: (to, text) → a line, or an error line.
    var send: (String, String) -> AgentToolResult
    /// The yes/no: (to, text, a warning line or nil) → yes?
    var confirm: (String, String, String?) -> Bool

    static let live = MessagesBackend(send: MessagesTools.liveSend, confirm: MessagesTools.liveConfirm)
}

enum MessagesTools {
    static let maxText = 1000

    /// "+1 (415) 555-0100" → "+14155550100"; an email stays as it is; nil for anything else.
    static func recipient(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if MailTools.isAddress(t) { return t }
        let digits = t.filter { $0.isNumber || $0 == "+" }
        let allowed = t.allSatisfy { $0.isNumber || " +-().".contains($0) }
        guard allowed, digits.filter(\.isNumber).count >= 7, digits.filter(\.isNumber).count <= 15,
              !digits.dropFirst().contains("+") else { return nil }
        return digits
    }

    /// True when the user's own words hold this recipient (digits compared without spaces or dashes).
    static func inRequest(_ to: String, request: String) -> Bool {
        if to.contains("@") { return request.lowercased().contains(to.lowercased()) }
        let want = to.filter(\.isNumber)
        guard !want.isEmpty else { return false }
        // Each phone-shaped run of the words on its own (unrelated digits never join into a match).
        let runs = ActionCommand.allMatches(#"\+?\d[\d\s().-]{5,}\d"#, request).map { $0.filter(\.isNumber) }
        return runs.contains { $0 == want || ($0.count >= 10 && want.hasSuffix($0)) || (want.count >= 10 && $0.hasSuffix(String(want.suffix(10)))) }
    }

    static let sendScript = """
    on run argv
      set target to item 1 of argv
      set msg to item 2 of argv
      tell application "Messages"
        set svc to 1st account whose service type = iMessage
        send msg to participant target of svc
      end tell
      return "Sent."
    end run
    """

    static func liveSend(_ to: String, _ text: String) -> AgentToolResult {
        let r = MailTools.osascript(sendScript, [to, text])
        if r.isError, r.text.contains("Automation") || r.text.contains("-1743") {
            return AgentToolResult(text: "Merlin may not control Messages. Allow it in System Settings > Privacy & Security > Automation.", isError: true)
        }
        return r
    }

    static func liveConfirm(_ to: String, _ text: String, _ warning: String?) -> Bool { liveConfirm(to, text, warning, agent: nil) }

    static func liveConfirm(_ to: String, _ text: String, _ warning: String?, agent: String?) -> Bool {
        AgentDialog.ask(AgentQuestion(title: AgentDialog.sendTitle(text, to: to, app: "Messages"), detail: text,
                                      warning: warning, yes: "Send", no: "Don't send", agent: agent))
    }
}

extension ActionCommand {
    /// Every match of a pattern in a text.
    static func allMatches(_ pattern: String, _ text: String) -> [String] {
        guard let rx = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = text as NSString
        return rx.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
