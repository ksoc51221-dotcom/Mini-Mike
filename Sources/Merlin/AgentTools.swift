import AppKit

// Part C1b: the tools Merlin's agent loop gives Claude. The C1 actions ARE the tools (one list, no second one): each
// fixed action type is a tool here, run by the same `ActionRunner`. Two more: `play_spotify_track` (a track address that
// Merlin checks with Spotify before it plays) and `run_script` (an AppleScript or shell command Claude writes, which never
// runs without Merlin's yes). A step cap stops a runaway loop.

/// One tool call's answer to Claude.
struct AgentToolResult: Equatable {
    var text: String
    var isError: Bool
}

final class AgentTools {
    typealias Action = LibraryAssistant.Action

    static let stepCap = 8
    static let scriptTimeout: TimeInterval = 30
    static let maxOutput = 1500
    /// The longest script Merlin runs: all of it fits in the yes/no dialog, so nothing hides past what the user sees.
    static let maxScript = 600

    let runner: ActionRunner
    /// The one confirmation for a script: (one plain line, the script itself) → yes?
    let confirmScript: (String, String) -> Bool
    /// Runs an approved script: (language "applescript" or "shell", source) → its output, or an error line.
    let runScript: (String, String) -> AgentToolResult
    /// The title Spotify gives a track id (its public oEmbed page), or nil if Spotify doesn't know it.
    let trackTitle: (String) -> String?
    /// Called with a short status line when a tool starts ("Searching…", "Adding Notion to the dock").
    var onStep: ((String) -> Void)?

    private(set) var steps = 0
    private(set) var capped = false
    /// Set when the run ended (a cap, the time limit): a yes that comes after that runs nothing.
    var cancelled = false
    /// True while a tool works on the main thread (a yes/no dialog may be open): the run's clock stops meanwhile.
    private(set) var inDialog = false

    init(runner: ActionRunner, confirmScript: @escaping (String, String) -> Bool,
         runScript: @escaping (String, String) -> AgentToolResult = AgentTools.liveRunScript,
         trackTitle: @escaping (String) -> String? = AgentTools.liveTrackTitle) {
        self.runner = runner
        self.confirmScript = confirmScript
        self.runScript = runScript
        self.trackTitle = trackTitle
    }

    // MARK: The list Claude sees

    private static func tool(_ name: String, _ desc: String, _ props: [String: Any] = [:], required: [String] = []) -> [String: Any] {
        ["name": name, "description": desc,
         "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any]]
    }
    private static let appProp: [String: Any] = ["app": ["type": "string", "description": "The app's name, as on the Mac"]]

    static let list: [[String: Any]] = [
        tool("dock_add", "Add an app to Merlin's dock (the ring at the right screen edge). The dock holds 6 apps.", appProp, required: ["app"]),
        tool("dock_remove", "Remove an app from Merlin's dock.", appProp, required: ["app"]),
        tool("app_open", "Open an app on the Mac.", appProp, required: ["app"]),
        tool("app_quit", "Quit an app (Merlin asks the user first).", appProp, required: ["app"]),
        tool("music_play", "Spotify: play / resume."),
        tool("music_pause", "Spotify: pause."),
        tool("music_next", "Spotify: next song."),
        tool("music_previous", "Spotify: previous song."),
        tool("music_star", "Star the song that is playing now in the user's song list."),
        tool("play_spotify_track", "Play one Spotify track. Find its address first with WebSearch (open.spotify.com/track/...). Merlin checks the address with Spotify and refuses it if the title doesn't match.",
             ["track_url": ["type": "string", "description": "https://open.spotify.com/track/<id> or spotify:track:<id>"],
              "title": ["type": "string", "description": "The song title the user asked for"]], required: ["track_url", "title"]),
        tool("timer_start", "Start a timer. It shows in Merlin's dock and a notification fires at the end.",
             ["minutes": ["type": "number"], "label": ["type": "string"]], required: ["minutes"]),
        tool("reminder_start", "Set a reminder: it shows in Merlin's dock (a reminder 'in the dock' means this) and a notification with the text fires at the end.",
             ["minutes": ["type": "number"], "text": ["type": "string", "description": "What to remember"]], required: ["minutes"]),
        tool("timer_cancel", "Cancel all running timers and reminders."),
        tool("routine_run", "Run one of the user's routines by name.", ["name": ["type": "string"]], required: ["name"]),
        tool("run_script", "Last resort, when no other tool fits: run an AppleScript or a zsh command on the Mac. Merlin shows the user your summary and the script and runs it only on a yes. Never use it for passwords.",
             ["language": ["type": "string", "enum": ["applescript", "shell"]],
              "script": ["type": "string"],
              "summary": ["type": "string", "description": "One plain sentence for the user: what it does"]],
             required: ["language", "script", "summary"]),
    ]

    static var names: [String] { list.compactMap { $0["name"] as? String } }

    // MARK: Calling

    /// The runner, the dialogs and the status line touch the UI: on the main thread. The rest (a web check, a script)
    /// runs on the caller's thread, so a slow one never freezes Merlin.
    private func onMain<T>(_ work: () -> T) -> T {
        withoutActuallyEscaping(work) { work in
            let run = { () -> T in
                self.inDialog = true
                defer { self.inDialog = false }
                return work()
            }
            return Thread.isMainThread ? run() : DispatchQueue.main.sync(execute: run)
        }
    }

    /// Call it off the main thread (the tool server does); tests call it on the main thread.
    func call(_ name: String, _ args: [String: Any]) -> AgentToolResult {
        steps += 1
        guard !cancelled else { return AgentToolResult(text: "This request was stopped.", isError: true) }
        guard steps <= Self.stepCap else {
            capped = true
            return AgentToolResult(text: "Step limit reached (\(Self.stepCap) tools). Stop now and tell the user what was done.", isError: true)
        }
        func str(_ k: String) -> String { (args[k] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        func minutes() -> Int? {
            let m = (args["minutes"] as? Double) ?? (args["minutes"] as? Int).map(Double.init) ?? Double(str("minutes"))
            guard let m else { return nil }
            let s = Int((m * 60).rounded())
            return (1...ActionCommand.maxSeconds).contains(s) ? s : nil
        }
        func act(_ a: Action, _ status: String) -> AgentToolResult {
            let out = onMain { () -> ActionRunner.Outcome in
                onStep?(status)
                return runner.run(a)
            }
            return AgentToolResult(text: out.line, isError: !out.ok)
        }

        switch name {
        case "dock_add": return act(Action(type: "dock_add", title: str("app")), "Adding \(str("app")) to the dock")
        case "dock_remove": return act(Action(type: "dock_remove", title: str("app")), "Removing \(str("app")) from the dock")
        case "app_open": return act(Action(type: "app_open", title: str("app")), "Opening \(str("app"))")
        case "app_quit": return act(Action(type: "app_quit", title: str("app")), "Quitting \(str("app"))")
        case "music_play", "music_pause", "music_next", "music_previous", "music_star":
            return act(Action(type: name), "Spotify")
        case "timer_start":
            guard let s = minutes() else { return AgentToolResult(text: "Give minutes between 0.02 and 1440.", isError: true) }
            return act(Action(type: "timer_start", title: str("label"), value: String(s)), "Setting a timer")
        case "reminder_start":
            guard let s = minutes() else { return AgentToolResult(text: "Give minutes between 0.02 and 1440.", isError: true) }
            return act(Action(type: "reminder_start", title: str("text"), value: String(s)), "Setting a reminder")
        case "timer_cancel": return act(Action(type: "timer_cancel"), "Cancelling timers")
        case "routine_run": return act(Action(type: "routine_run", title: str("name")), "Running \(str("name"))")
        case "play_spotify_track": return playTrack(str("track_url"), title: str("title"))
        case "run_script": return script(str("language"), str("script"), summary: str("summary"))
        default: return AgentToolResult(text: "No tool called \(name).", isError: true)
        }
    }

    /// The 22-character id in an open.spotify.com/track URL or a spotify:track: URI, or nil.
    static func trackID(_ s: String) -> String? {
        let patterns = [#"^https?://open\.spotify\.com/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?track/([A-Za-z0-9]{22})(?:[?#/].*)?$"#,
                        #"^open\.spotify\.com/(?:intl-[a-z]{2}(?:-[a-z]{2})?/)?track/([A-Za-z0-9]{22})(?:[?#/].*)?$"#,
                        #"^spotify:track:([A-Za-z0-9]{22})$"#]
        for p in patterns { if let g = ActionCommand.match(p, s), let id = g.first { return id } }
        return nil
    }

    /// Plays only after Spotify itself says what the track is, and only if that is the song asked for (a web page
    /// that names one song and links another is refused).
    private func playTrack(_ url: String, title: String) -> AgentToolResult {
        guard let id = Self.trackID(url) else { return AgentToolResult(text: "That is not a Spotify track address.", isError: true) }
        onMain { onStep?("Checking the song with Spotify") }
        guard let real = trackTitle(id) else { return AgentToolResult(text: "Spotify doesn't know that track.", isError: true) }
        let a = ActionCommand.key(real), b = ActionCommand.key(title)
        guard !b.isEmpty, a.contains(b) || b.contains(a) else {
            return AgentToolResult(text: "That address is “\(real)”, not “\(title)”. Find the right track.", isError: true)
        }
        let out = onMain { runner.run(Action(type: "music_play_song", title: real, key: "spotify:track:\(id)")) }
        return AgentToolResult(text: out.line, isError: !out.ok)
    }

    /// Never runs without a yes. A no is final for this request.
    private func script(_ language: String, _ source: String, summary: String) -> AgentToolResult {
        guard ["applescript", "shell"].contains(language), !source.isEmpty else {
            return AgentToolResult(text: "language must be applescript or shell, with a script.", isError: true)
        }
        guard source.count <= Self.maxScript else {
            return AgentToolResult(text: "Too long to show the user: keep the script under \(Self.maxScript) characters.", isError: true)
        }
        let line = summary.isEmpty ? "Run a \(language == "shell" ? "shell command" : "script") on your Mac" : summary
        guard onMain({ confirmScript(line, source) }) else {
            return AgentToolResult(text: "The user said no. Do not try another way; tell the user it was not done.", isError: true)
        }
        guard !cancelled else { return AgentToolResult(text: "This request was stopped before the yes came.", isError: true) }
        onMain { onStep?(line) }
        return runScript(language, source)
    }

    // MARK: Live

    static func liveRunScript(_ language: String, _ source: String) -> AgentToolResult {
        let p = Process()
        if language == "shell" {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", source]
        } else {
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", source]
        }
        p.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        do { try p.run() } catch { return AgentToolResult(text: "It could not start: \(error.localizedDescription)", isError: true) }
        let deadline = Date().addingTimeInterval(scriptTimeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { p.terminate(); return AgentToolResult(text: "Stopped after \(Int(scriptTimeout)) s.", isError: true) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > maxOutput { text = String(text.prefix(maxOutput)) + "…" }
        let ok = p.terminationStatus == 0
        return AgentToolResult(text: ok ? (text.isEmpty ? "Done." : text) : "Failed (\(p.terminationStatus)): \(text)", isError: !ok)
    }

    /// Spotify's public oEmbed page: the track's title, no key needed. Only the 22-character id goes out.
    static func liveTrackTitle(_ id: String) -> String? {
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              let url = URL(string: "https://open.spotify.com/oembed?url=https://open.spotify.com/track/\(id)") else { return nil }
        var title: String?
        let done = DispatchSemaphore(value: 0)
        var req = URLRequest(url: url)
        req.timeoutInterval = 8
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200, let data,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { title = obj["title"] as? String }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 10)
        return title
    }

    /// The live yes/no for a script: the plain line, then the script itself, so a misleading summary can be seen.
    static func liveConfirmScript(_ line: String, _ source: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Merlin wants to: \(line)"
        alert.informativeText = source // all of it: `maxScript` keeps it short enough to show
        // "Don't run" is the Return button; "Run it" has no key, so a key pressed for another app can't say yes.
        alert.addButton(withTitle: "Don't run")
        let run = alert.addButton(withTitle: "Run it")
        run.keyEquivalent = ""
        alert.alertStyle = .warning
        return alert.runModal() == .alertSecondButtonReturn
    }
}
