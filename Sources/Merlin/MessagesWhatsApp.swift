import AppKit

// WhatsApp for the agents (2026-11-27, after an agent tried to type into WhatsApp with System Events keystrokes and
// Merlin's screen got stuck). The tool finds the person's number in Contacts, shows one yes dialog with the person, the
// number and the text, and on a yes opens WhatsApp's own link `whatsapp://send?phone=…&text=…`: WhatsApp opens that
// chat with the text ready, and Merlin presses Return there to send it. No keystrokes, no search inside WhatsApp, no
// Accessibility permission. No number in Contacts: the tool says so and nothing happens.

/// The WhatsApp side of `whatsapp_send`; tests use a fake.
struct WhatsAppBackend {
    /// Opens the link (WhatsApp shows the chat with the text ready).
    var open: (URL) -> AgentToolResult
    /// The one yes/no: (name, number as shown, text, warning or nil) → yes?
    var confirm: (String, String, String, String?) -> Bool

    static let live = WhatsAppBackend(open: WhatsAppTools.liveOpen,
                                      confirm: { n, p, t, w in WhatsAppTools.liveConfirm(n, p, t, w, agent: nil) })
}

enum WhatsAppTools {
    static let maxText = 1000

    /// "+44 7700 900123" → ("447700900123", true); "0044 7700…" → ("447700…", true); "07700 900123" → (…, false).
    /// nil for fewer than 7 digits or more than 15.
    static func number(_ raw: String) -> (digits: String, international: Bool)? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.allSatisfy({ $0.isNumber || " +-().".contains($0) }) else { return nil }
        var digits = s.filter(\.isNumber)
        var international = s.hasPrefix("+")
        if !international, digits.hasPrefix("00") { digits.removeFirst(2); international = true }
        guard (7...15).contains(digits.count) else { return nil }
        return (digits, international)
    }

    /// whatsapp://send?phone=447700900123&text=hi%20there (every character but letters, digits and -._~ is encoded, so a
    /// "+" or "&" in the text stays text).
    static func link(digits: String, text: String) -> URL? {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        guard let t = text.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: "whatsapp://send?phone=\(digits)&text=\(t)")
    }

    /// The people in contact lines ("Name | +44…, 0770…,  | a@b.com") with their phone numbers.
    static func people(inContactLines text: String) -> [(name: String, phones: [String])] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            let phones = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { number($0) != nil }
            return (parts[0], phones)
        }
    }

    // MARK: Live

    static func liveOpen(_ url: URL) -> AgentToolResult {
        guard NSWorkspace.shared.urlForApplication(toOpen: url) != nil else {
            return AgentToolResult(text: "WhatsApp is not on this Mac. Install WhatsApp from the App Store, then ask again.", isError: true)
        }
        let open = { NSWorkspace.shared.open(url) }
        let ok = Thread.isMainThread ? open() : DispatchQueue.main.sync(execute: open)
        return ok ? AgentToolResult(text: "Opened.", isError: false)
                  : AgentToolResult(text: "WhatsApp did not open.", isError: true)
    }

    static func liveConfirm(_ name: String, _ shown: String, _ text: String, _ warning: String?, agent: String?) -> Bool {
        AgentDialog.ask(AgentQuestion(title: AgentDialog.sendTitle(text, to: name, app: "WhatsApp"),
                                      detail: "To: \(name)" + (name == shown ? "" : ", \(shown)") + "\n\n\(text)\n\nWhatsApp opens with this text ready. Press Return there to send it.",
                                      warning: warning, yes: "Open WhatsApp", no: "Don't send", agent: agent))
    }
}
