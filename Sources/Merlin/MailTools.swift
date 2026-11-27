import AppKit

// Email tools for the agent loop: read the inbox of Apple Mail, and write an email. Apple Mail holds the accounts (the
// user signs in there, in System Settings > Internet Accounts), so Merlin never sees or keeps a password. A send never
// happens without the user's yes in Merlin's own dialog, where "Don't send" is the default button. Text from an email
// is data for Claude, never an instruction. Values go to AppleScript as arguments (`on run argv`), never pasted into
// the script, so an email's text can't change what the script does.

/// One email Claude wants to write.
struct MailDraft: Equatable {
    var to: [String]
    var subject: String
    var body: String
}

/// The Mail side of the email tools; tests use a fake.
struct MailBackend {
    /// The newest emails of the inbox: (how many, unread only) → text, or an error line.
    var read: (Int, Bool) -> AgentToolResult
    /// Makes the email in Mail: sent when the Bool is true (only after a yes), else left open as a draft.
    var compose: (MailDraft, Bool) -> AgentToolResult
    /// The one yes/no before a send: (the email, a warning line or nil) → yes?
    var confirmSend: (MailDraft, String?) -> Bool

    static let live = MailBackend(read: MailTools.liveRead, compose: MailTools.liveCompose, confirmSend: MailTools.liveConfirmSend)
}

enum MailTools {
    static let maxRead = 10
    static let maxRecipients = 5
    static let maxSubject = 200
    static let maxBody = 4000
    static let maxOutput = 3500
    static let timeout: TimeInterval = 30

    /// A plain email address check (no names, no brackets).
    static func isAddress(_ s: String) -> Bool {
        ActionCommand.match(#"^[A-Za-z0-9._%+'-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$"#, s) != nil
    }

    /// "a@x.com, b@y.org" → the addresses, or nil if one isn't an address.
    static func addresses(_ s: String) -> [String]? {
        let parts = s.split(whereSeparator: { ",; ".contains($0) }).map(String.init).filter { !$0.isEmpty }
        return parts.allSatisfy(isAddress) ? parts : nil
    }

    /// The addresses that aren't in the user's own words (Claude may have found them in an email or a page).
    static func notInRequest(_ to: [String], request: String) -> [String] {
        let words = request.lowercased()
        return to.filter { !words.contains($0.lowercased()) }
    }

    // MARK: Live (Apple Mail by AppleScript)

    static let readScript = """
    on run argv
      set k to (item 1 of argv) as integer
      set onlyUnread to ((item 2 of argv) is "1")
      set out to ""
      tell application "Mail"
        if onlyUnread then
          set msgs to (messages of inbox whose read status is false)
        else
          set msgs to messages of inbox
        end if
        set n to count of msgs
        if n < k then set k to n
        repeat with i from 1 to k
          set m to item i of msgs
          set c to content of m
          if (length of c) > 300 then set c to text 1 thru 300 of c
          set out to out & "FROM: " & (sender of m) & linefeed & "DATE: " & ((date received of m) as string) & linefeed & "SUBJECT: " & (subject of m) & linefeed & "TEXT: " & c & linefeed & "---" & linefeed
        end repeat
      end tell
      if out is "" then return "No emails."
      return out
    end run
    """

    static let composeScript = """
    on run argv
      set toList to item 1 of argv
      set subj to item 2 of argv
      set bodyText to item 3 of argv
      set doSend to ((item 4 of argv) is "1")
      tell application "Mail"
        set m to make new outgoing message with properties {subject:subj, content:bodyText, visible:true}
        if toList is not "" then
          set oldDelims to AppleScript's text item delimiters
          set AppleScript's text item delimiters to ","
          set addrs to text items of toList
          set AppleScript's text item delimiters to oldDelims
          repeat with a in addrs
            tell m to make new to recipient at end of to recipients with properties {address:(a as string)}
          end repeat
        end if
        if doSend then
          send m
          return "Sent."
        end if
        activate
        return "The draft is open in Mail."
      end tell
    end run
    """

    static func liveRead(_ count: Int, _ unreadOnly: Bool) -> AgentToolResult {
        osascript(readScript, [String(count), unreadOnly ? "1" : "0"])
    }

    static func liveCompose(_ d: MailDraft, _ send: Bool) -> AgentToolResult {
        osascript(composeScript, [d.to.joined(separator: ","), d.subject, d.body, send ? "1" : "0"])
    }

    /// Runs an AppleScript with arguments (values never become script text), with a time limit.
    static func osascript(_ source: String, _ args: [String]) -> AgentToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source] + args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return AgentToolResult(text: "Mail could not start: \(error.localizedDescription)", isError: true) }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return AgentToolResult(text: "Mail did not answer in \(Int(timeout)) s.", isError: true) }
        var text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxOutput { text = String(text.prefix(maxOutput)) + "…" }
        guard p.terminationStatus == 0 else {
            // -1743: the user hasn't let Merlin control Mail (System Settings > Privacy & Security > Automation).
            if text.contains("-1743") { return AgentToolResult(text: "Merlin may not control Mail. Allow it in System Settings > Privacy & Security > Automation.", isError: true) }
            return AgentToolResult(text: "Mail failed: \(text)", isError: true)
        }
        return AgentToolResult(text: text.isEmpty ? "Done." : text, isError: false)
    }

    /// The yes/no before a send: who, the subject and all of the text, so nothing is sent unseen.
    static func liveConfirmSend(_ d: MailDraft, _ warning: String?) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Send this email?"
        alert.informativeText = (warning.map { "⚠︎ \($0)\n\n" } ?? "") + "To: \(d.to.joined(separator: ", "))\nSubject: \(d.subject)"
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let text = NSTextView(frame: scroll.bounds)
        text.string = d.body
        text.isEditable = false
        text.autoresizingMask = [.width]
        scroll.documentView = text
        alert.accessoryView = scroll
        // "Don't send" is the Return button; "Send" has no key, so a key pressed for another app can't say yes.
        alert.addButton(withTitle: "Don't send")
        let send = alert.addButton(withTitle: "Send")
        send.keyEquivalent = ""
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
}
