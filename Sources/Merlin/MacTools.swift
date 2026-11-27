import AppKit
import EventKit

// More reach for the agents, with no new account: Contacts (a name to a number or an address), Calendar (read the next
// days; add an event only after a yes), Apple Reminders (add, list), a file search in Documents, Desktop and Downloads
// (names and places only, read-only), and Apple Shortcuts (run one by name, only after a yes). macOS asks the user the
// first time for each: "Merlin wants to control Contacts / Reminders" (Automation), Calendars (already asked by the
// calendar feature), Documents / Desktop / Downloads folders. Merlin never clicks those prompts. Values go to
// AppleScript as arguments, never as script text.

struct MacBackend {
    /// People whose name holds the words: "Name | phones | emails" lines.
    var contacts: (String) -> AgentToolResult
    /// Events from now for that many days.
    var calendarList: (Int) -> AgentToolResult
    /// Adds an event (only after `confirmEvent`): (title, start, minutes) → a line.
    var calendarAdd: (String, Date, Int) -> AgentToolResult
    var confirmEvent: (String, Date, Int) -> Bool
    /// Adds an Apple reminder: (title, due or nil).
    var remindersAdd: (String, Date?) -> AgentToolResult
    var confirmReminder: (String, Date?) -> Bool
    var remindersList: () -> AgentToolResult
    /// Files whose name holds the words, in Documents, Desktop and Downloads.
    var files: (String) -> AgentToolResult
    var shortcutNames: () -> [String]
    /// Runs a Shortcut (only after `confirmShortcut`): (name, input or "") → its output.
    var runShortcut: (String, String) -> AgentToolResult
    var confirmShortcut: (String, String) -> Bool

    static let live = live(agent: nil)

    /// The live backend; `agent` names the agent in each of its dialogs ("Agent “Price ceilings”: …").
    static func live(agent: String?) -> MacBackend {
        let who = agent.map { "Agent “\($0)”: " } ?? ""
        return MacBackend(contacts: MacTools.liveContacts, calendarList: MacTools.liveCalendarList,
                          calendarAdd: MacTools.liveCalendarAdd,
                          confirmEvent: { t, d, m in MacTools.confirm(who + "Add this event to your calendar?", "\(t)\n\(MacTools.say(d)), \(m) minutes", yes: "Add") },
                          remindersAdd: MacTools.liveRemindersAdd,
                          confirmReminder: { t, d in MacTools.confirm(who + "Add this to Apple Reminders?", t + (d.map { "\nDue \(MacTools.say($0))" } ?? ""), yes: "Add") },
                          remindersList: MacTools.liveRemindersList,
                          files: MacTools.liveFiles, shortcutNames: MacTools.liveShortcutNames, runShortcut: MacTools.liveRunShortcut,
                          confirmShortcut: { n, i in MacTools.confirm(who + "Run the Shortcut “\(n)”?", i.isEmpty ? "With no input." : "Input:\n\(i)", yes: "Run it") })
    }
}

enum MacTools {
    static let maxDays = 31
    static let maxFiles = 15

    /// "2026-11-28T15:00", "2026-11-28 15:00" or "2026-11-28" (9:00) in the Mac's time zone.
    static func date(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm:ss"] {
            f.dateFormat = format
            if let d = f.date(from: s.trimmingCharacters(in: .whitespaces)) { return d }
        }
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespaces)).map { $0.addingTimeInterval(9 * 3600) }
    }

    static func say(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMMM, HH:mm"
        return f.string(from: d)
    }

    /// The phone numbers and addresses in contact lines ("Name | +1 415… , … | a@b.com").
    static func recipients(inContactLines text: String) -> [String] {
        text.split(separator: "\n").flatMap { line -> [String] in
            line.split(separator: "|").dropFirst().flatMap { $0.split(separator: ",") }
                .compactMap { MessagesTools.recipient(String($0)) }
        }
    }

    // MARK: Live

    static let contactsScript = """
    on run argv
      set q to item 1 of argv
      set out to ""
      tell application "Contacts"
        set found to (every person whose name contains q)
        set n to 0
        repeat with p in found
          set n to n + 1
          if n > 8 then exit repeat
          set ph to ""
          repeat with v in (value of phones of p)
            set ph to ph & v & ", "
          end repeat
          set em to ""
          repeat with v in (value of emails of p)
            set em to em & v & ", "
          end repeat
          set out to out & (name of p) & " | " & ph & " | " & em & linefeed
        end repeat
      end tell
      if out is "" then return "No contact matches."
      return out
    end run
    """

    static func liveContacts(_ q: String) -> AgentToolResult { MailTools.osascript(contactsScript, [q]) }

    static func liveCalendarList(_ days: Int) -> AgentToolResult {
        guard CalendarStore.hasAccess else {
            return AgentToolResult(text: "Merlin doesn't have access to your calendars. Allow it in System Settings → Privacy & Security → Calendars.", isError: true)
        }
        let store = EKEventStore()
        let now = Date()
        let pred = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(Double(days) * 86400), calendars: nil)
        let events = store.events(matching: pred).sorted { $0.startDate < $1.startDate }.prefix(30)
        guard !events.isEmpty else { return AgentToolResult(text: "No events in the next \(days) days.", isError: false) }
        return AgentToolResult(text: events.map { "\(say($0.startDate)): \($0.title ?? "Event")" + ($0.location.map { " (\($0))" } ?? "") }
            .joined(separator: "\n"), isError: false)
    }

    static func liveCalendarAdd(_ title: String, _ start: Date, _ minutes: Int) -> AgentToolResult {
        guard let dest = CalendarStore.preferred() else { return AgentToolResult(text: "There is no calendar Merlin can write to.", isError: true) }
        let draft = CalendarIntent.Draft(title: title, start: start, end: start.addingTimeInterval(Double(minutes) * 60))
        do { return AgentToolResult(text: try CalendarStore.add(draft, to: dest), isError: false) }
        catch { return AgentToolResult(text: error.localizedDescription, isError: true) }
    }

    static let remindersAddScript = """
    on run argv
      set t to item 1 of argv
      tell application "Reminders"
        if (count of argv) > 1 then
          set d to current date
          set day of d to 1
          set year of d to (item 2 of argv) as integer
          set month of d to (item 3 of argv) as integer
          set day of d to (item 4 of argv) as integer
          set time of d to ((item 5 of argv) as integer) * 3600 + ((item 6 of argv) as integer) * 60
          make new reminder with properties {name:t, due date:d}
        else
          make new reminder with properties {name:t}
        end if
      end tell
      return "Added to Reminders."
    end run
    """

    static func liveRemindersAdd(_ title: String, _ due: Date?) -> AgentToolResult {
        var args = [title]
        if let due {
            let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            args += [c.year, c.month, c.day, c.hour, c.minute].map { String($0 ?? 0) }
        }
        return MailTools.osascript(remindersAddScript, args)
    }

    static let remindersListScript = """
    tell application "Reminders"
      set out to ""
      set n to 0
      repeat with r in (every reminder whose completed is false)
        set n to n + 1
        if n > 20 then exit repeat
        set out to out & (name of r) & linefeed
      end repeat
    end tell
    if out is "" then return "No open reminders."
    return out
    """

    static func liveRemindersList() -> AgentToolResult { MailTools.osascript(remindersListScript, []) }

    static func liveFiles(_ q: String) -> AgentToolResult {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["-onlyin", home + "/Documents", "-onlyin", home + "/Desktop", "-onlyin", home + "/Downloads", "-name", q]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return AgentToolResult(text: "The file search didn't start.", isError: true) }
        let paths = String(decoding: collect(p, out, timeout: 15).data, as: UTF8.self).split(separator: "\n").prefix(maxFiles)
        guard !paths.isEmpty else { return AgentToolResult(text: "No file names match “\(q)”.", isError: false) }
        return AgentToolResult(text: paths.map { $0.replacingOccurrences(of: home, with: "~") }.joined(separator: "\n"), isError: false)
    }

    static func liveShortcutNames() -> [String] {
        let r = shell("/usr/bin/shortcuts", ["list"], timeout: 15)
        return r.isError ? [] : r.text.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    static func liveRunShortcut(_ name: String, _ input: String) -> AgentToolResult {
        var args = ["run", name]
        var inputFile: URL?
        if !input.isEmpty {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-shortcut-\(UUID().uuidString).txt")
            try? input.write(to: url, atomically: true, encoding: .utf8)
            args += ["--input-path", url.path]
            inputFile = url
        }
        let outURL = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-shortcut-out-\(UUID().uuidString).txt")
        args += ["--output-path", outURL.path]
        defer {
            inputFile.map { try? FileManager.default.removeItem(at: $0) }
            try? FileManager.default.removeItem(at: outURL)
        }
        let r = shell("/usr/bin/shortcuts", args, timeout: 60)
        guard !r.isError else { return r }
        let output = (try? String(contentsOf: outURL, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return AgentToolResult(text: output.isEmpty ? "The Shortcut ran." : "The Shortcut ran. Its output (data): " + String(output.prefix(1500)), isError: false)
    }

    static func shell(_ path: String, _ args: [String], timeout: TimeInterval) -> AgentToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return AgentToolResult(text: "It didn't start: \(error.localizedDescription)", isError: true) }
        let got = collect(p, out, timeout: timeout)
        if got.timedOut { return AgentToolResult(text: "It took over \(Int(timeout)) s and was stopped.", isError: true) }
        let text = String(decoding: got.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentToolResult(text: p.terminationStatus == 0 ? text : "It failed: \(text.prefix(300))", isError: p.terminationStatus != 0)
    }

    /// Reads a process's output while it runs (a full pipe, about 64 KB, would stop it), up to a time limit.
    static func collect(_ p: Process, _ pipe: Pipe, timeout: TimeInterval) -> (data: Data, timedOut: Bool) {
        final class Box { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        let timedOut = p.isRunning
        if timedOut { p.terminate() }
        _ = done.wait(timeout: .now() + 2)
        return (box.data, timedOut)
    }

    /// A yes/no with "Don't" as the Return button and the yes button with no key.
    static func confirm(_ title: String, _ detail: String, yes: String) -> Bool {
        AgentDialog.ask(AgentQuestion(title: title, detail: detail, yes: yes, no: "Don't " + yes.lowercased()))
    }
}
