import AppKit
import Combine
import UserNotifications

// Merlin's fixed actions (Part C1): the dock and apps, music, timers and reminders, routines. Spoken or typed words are read
// by strict rules on this Mac (zero tokens). Any other request to act goes to the agent loop (`AgentLoop`), where these
// same actions are Claude's tools (`AgentTools`).
//
// The actions are `LibraryAssistant.Action` values (one list for voice, the Ask box and the Library Assistant):
//   dock_add / dock_remove   title = the app name as said
//   app_open / app_quit      title = the app's name, key = its bundle id
//   music_play / music_pause / music_next / music_previous / music_star
//   music_play_song          title = the song's name, key = its spotify:track: URI
//   timer_start              value = seconds
//   reminder_start           value = seconds, title = what to remember (may be empty)
//   timer_cancel
//   routine_run              title = the routine's name

/// What the rules may match against: the apps on this Mac, the saved songs, the routines.
struct ActionContext {
    var apps: [DockApp] = []
    var songs: [(name: String, uri: String)] = []
    var routines: [Routine] = []
}

/// One phrase runs several actions. Written in Settings as one line: "Study time: open Notion; start a 50 minute timer; play".
struct Routine: Equatable {
    var name: String
    var steps: [String]

    /// Every line "name: step; step; …" with a name and at least one step. Other lines are skipped.
    static func parse(_ text: String) -> [Routine] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty else { return nil }
            let steps = parts[1].split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return steps.isEmpty ? nil : Routine(name: parts[0], steps: steps)
        }
    }
}

enum ActionCommand {
    typealias Action = LibraryAssistant.Action

    /// Every action type, and which ones need one confirmation first.
    static let types: Set<String> = ["dock_add", "dock_remove", "app_open", "app_quit", "music_play", "music_pause", "music_next",
                                     "music_previous", "music_play_song", "music_star", "timer_start", "reminder_start",
                                     "timer_cancel", "routine_run"]
    static let confirmTypes: Set<String> = ["app_quit"]
    static let maxWords = 14
    static let maxSeconds = 24 * 3600

    static let playPhrases: Set<String> = ["play", "play music", "play the music", "resume", "resume music", "resume the music",
                                           "unpause", "start the music", "continue the music", "play spotify"]
    static let pausePhrases: Set<String> = ["pause", "pause music", "pause the music", "pause spotify", "pause the song",
                                            "stop the music", "stop music", "stop playing", "stop the song"]
    static let nextPhrases: Set<String> = ["next", "next song", "next track", "skip", "skip it", "skip this", "skip song",
                                           "skip this song", "skip the song", "skip track", "skip this track", "play the next song"]
    static let previousPhrases: Set<String> = ["previous", "previous song", "previous track", "last song", "go back a song",
                                               "play the previous song", "play the last song"]

    private static let dock = #"(?:the |my )?(?:edge )?(?:dock|rotation|ring)"#
    /// Dictation often writes "doc": accepted only when the name is an app on this Mac ("add this to my doc" stays a question).
    private static let doc = #"(?:the |my )?doc"#
    private static let unit = #"(seconds?|secs?|minutes?|mins?|hours?|hrs?)"#
    private static let num = #"(\d+(?:\.\d+)?|[a-z]+(?: [a-z]+)?)"#

    /// Lower case, plain apostrophes, no end punctuation, "please" off, one space between words.
    static func normalize(_ text: String) -> String {
        var s = text.lowercased().replacingOccurrences(of: "’", with: "'")
        s = s.replacingOccurrences(of: #"[.!?,;:]+"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: #"^please |^can you please | please$"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "half an hour", with: "30 minutes").replacingOccurrences(of: "an hour and a half", with: "90 minutes")
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// The action these words ask for, or nil (then they are a question, a note command, calendar or video as before).
    /// `text` should already have the wake-up words off (`CommandCenter.cleaned`).
    static func parse(_ text: String, context: ActionContext) -> Action? {
        let s = normalize(text)
        let words = s.split(separator: " ").map(String.init)
        guard let first = words.first, words.count <= maxWords, !NoteCommand.questionWords.contains(first) else { return nil }

        // Music: the whole sentence is the command.
        if playPhrases.contains(s) { return Action(type: "music_play") }
        if pausePhrases.contains(s) { return Action(type: "music_pause") }
        if nextPhrases.contains(s) { return Action(type: "music_next") }
        if previousPhrases.contains(s) { return Action(type: "music_previous") }
        if match(#"^(?:star|like|heart|save) (?:this |the |that )?(?:song|track)$"#, s) != nil { return Action(type: "music_star") }

        // Timers and reminders.
        if match(#"^(?:cancel|stop|end|clear) (?:the |my |all |all my )?(?:timers?|reminders?)$"#, s) != nil { return Action(type: "timer_cancel") }
        if let g = match(#"^(?:start|set|make)(?: me)?(?: a| an)? "# + num + " " + unit + #" timer$"#, s)
            ?? match(#"^(?:start|set|make)(?: me)?(?: a| an)? timer for "# + num + " " + unit + "$", s)
            ?? match(#"^(?:a |an )?"# + num + " " + unit + " timer$", s)
            ?? match(#"^timer (?:for )?"# + num + " " + unit + "$", s),
           let secs = seconds(g[0], g[1]) {
            return Action(type: "timer_start", value: String(secs))
        }
        if let g = match(#"^remind me in "# + num + " " + unit + #"(?: to (.+))?$"#, s), let secs = seconds(g[0], g[1]) {
            return Action(type: "reminder_start", title: g.count > 2 ? g[2] : "", value: String(secs))
        }
        if let g = match(#"^remind me to (.+) in "# + num + " " + unit + "$", s), let secs = seconds(g[1], g[2]) {
            return Action(type: "reminder_start", title: g[0], value: String(secs))
        }
        if let g = match(#"^in "# + num + " " + unit + #" remind me(?: to (.+))?$"#, s), let secs = seconds(g[0], g[1]) {
            return Action(type: "reminder_start", title: g.count > 2 ? g[2] : "", value: String(secs))
        }

        // The dock: "… to the dock" / "… from the dock" anchors it (the app is found when it runs).
        if let g = match(#"^(?:add|put|pin|place) (.+?) (?:to|in|into|on|onto) "# + dock + "$", s) {
            return Action(type: "dock_add", title: appPhrase(g[0]))
        }
        if let g = match(#"^(?:remove|take|unpin|drop|delete) (.+?) (?:from|off|off of|out of) "# + dock + "$", s) {
            return Action(type: "dock_remove", title: appPhrase(g[0]))
        }
        if let g = match(#"^(?:add|put|pin|place) (.+?) (?:to|in|into|on|onto) "# + doc + "$", s),
           findApp(appPhrase(g[0]), in: context.apps, exact: true) != nil {
            return Action(type: "dock_add", title: appPhrase(g[0]))
        }
        if let g = match(#"^(?:remove|take|unpin|drop) (.+?) (?:from|off|off of|out of) "# + doc + "$", s),
           findApp(appPhrase(g[0]), in: context.apps, exact: true) != nil {
            return Action(type: "dock_remove", title: appPhrase(g[0]))
        }

        // Routines: "run study time", "start my study time routine", or the routine's name alone.
        let routineName = match(#"^(?:run|start|do|begin) (?:my |the )?(.+?)(?: routine)?$"#, s)?.first ?? s.replacingOccurrences(of: #" routine$"#, with: "", options: .regularExpression)
        if let r = context.routines.first(where: { key($0.name) == key(routineName) }) {
            return Action(type: "routine_run", title: r.name)
        }

        // "Play <a saved song>" (only a song in the list; anything else stays a question).
        if let g = match(#"^play (?:the song |my song )?(.+?)(?: on spotify)?$"#, s),
           let song = context.songs.first(where: { key($0.name) == key(g[0]) }) {
            return Action(type: "music_play_song", title: song.name, key: song.uri)
        }

        // Open or quit: only an app that is on this Mac by that exact name ("open the cheat sheet" stays a question).
        if let g = match(#"^(?:open|launch|start|run) (?:up )?(.+)$"#, s), let app = findApp(appPhrase(g[0]), in: context.apps, exact: true) {
            return Action(type: "app_open", title: app.name, key: app.bundleID)
        }
        if let g = match(#"^(?:quit|close) (.+)$"#, s), let app = findApp(appPhrase(g[0]), in: context.apps, exact: true) {
            return Action(type: "app_quit", title: app.name, key: app.bundleID)
        }
        return nil
    }

    // MARK: Helpers

    /// "the Notion app" → "notion".
    static func appPhrase(_ s: String) -> String {
        s.replacingOccurrences(of: #"^(?:the|my) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" (?:app|application)$"#, with: "", options: .regularExpression)
    }

    /// Letters and digits only, lower case: "X Code" and "Xcode" are the same key.
    static func key(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// The app with that name. Exact (same key) first; unless `exact`, then the one app whose name starts with it or
    /// holds it. Never a guess between two.
    static func findApp(_ name: String, in apps: [DockApp], exact: Bool) -> DockApp? {
        let k = key(name)
        guard !k.isEmpty else { return nil }
        if let hit = apps.first(where: { key($0.name) == k }) { return hit }
        if exact { return nil }
        let starts = apps.filter { key($0.name).hasPrefix(k) }
        if starts.count == 1 { return starts[0] }
        let holds = apps.filter { key($0.name).contains(k) }
        return holds.count == 1 ? holds[0] : nil
    }

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "twenty five": 25, "thirty": 30, "forty": 40,
        "forty five": 45, "fifty": 50, "sixty": 60, "ninety": 90, "a couple": 2, "a few": 3]

    /// "25" / "twenty five" + "minutes" → 1500. Nil for an unknown number or outside 1 second … 24 hours.
    static func seconds(_ n: String, _ unit: String) -> Int? {
        guard let value = Double(n) ?? numberWords[n] else { return nil }
        let per: Double = unit.hasPrefix("h") ? 3600 : unit.hasPrefix("m") ? 60 : 1
        let total = Int((value * per).rounded())
        return (1...maxSeconds).contains(total) ? total : nil
    }

    /// "25 min", "1 h 30 min", "45 s".
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 && h == 0 { parts.append("\(s) s") }
        return parts.joined(separator: " ")
    }

    /// The capture groups of the whole-string match (empty groups dropped from the end), or nil.
    static func match(_ pattern: String, _ s: String) -> [String]? {
        guard let rx = try? NSRegularExpression(pattern: pattern),
              let m = rx.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        var groups: [String] = []
        for i in 1..<max(m.numberOfRanges, 1) {
            if let r = Range(m.range(at: i), in: s) { groups.append(String(s[r])) } else { groups.append("") }
        }
        while groups.last == "" { groups.removeLast() }
        return groups
    }
}

// MARK: - Timers and reminders

struct AssistantTimer: Codable, Equatable, Identifiable {
    var id: UUID
    var end: Date
    var seconds: Int
    var label: String
    var isReminder: Bool
}

/// Running timers and reminders. Saved, so the dock card still shows them after a restart; the macOS notification itself is
/// scheduled with the system, so it fires even when Merlin is not running.
final class TimerStore: ObservableObject {
    static let shared = TimerStore()
    static let defaultsKey = "assistantTimers"

    @Published private(set) var items: [AssistantTimer] = []

    private let defaults: UserDefaults
    private let now: () -> Date
    /// Schedules (id, title, body, seconds) and cancels (ids) the system notifications. Tests pass fakes.
    let schedule: (UUID, String, String, Int) -> Void
    let unschedule: ([UUID]) -> Void
    /// Called on the main queue when a timer ends while Merlin runs.
    var onFinish: ((AssistantTimer) -> Void)?
    private var work: [UUID: DispatchWorkItem] = [:]

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init,
         schedule: @escaping (UUID, String, String, Int) -> Void = TimerStore.systemSchedule,
         unschedule: @escaping ([UUID]) -> Void = TimerStore.systemUnschedule) {
        self.defaults = defaults
        self.now = now
        self.schedule = schedule
        self.unschedule = unschedule
        if let data = defaults.data(forKey: Self.defaultsKey), let saved = try? JSONDecoder().decode([AssistantTimer].self, from: data) {
            items = saved.filter { $0.end > now() }
            items.forEach(arm)
        }
    }

    /// The soonest one to end (what the dock card shows).
    var next: AssistantTimer? { items.min { $0.end < $1.end } }

    @discardableResult
    func start(seconds: Int, label: String, isReminder: Bool) -> AssistantTimer {
        let t = AssistantTimer(id: UUID(), end: now().addingTimeInterval(TimeInterval(seconds)), seconds: seconds, label: label, isReminder: isReminder)
        items.append(t)
        save()
        let title = isReminder ? "Reminder" : "Timer done"
        let body = label.isEmpty ? (isReminder ? "Your \(ActionCommand.duration(seconds)) reminder." : "Your \(ActionCommand.duration(seconds)) timer is done.") : label
        schedule(t.id, title, body, seconds)
        arm(t)
        return t
    }

    /// Stops all of them. Returns how many there were.
    @discardableResult
    func cancelAll() -> Int {
        let ids = items.map(\.id)
        ids.forEach { work[$0]?.cancel(); work[$0] = nil }
        unschedule(ids)
        items = []
        save()
        return ids.count
    }

    private func arm(_ t: AssistantTimer) {
        let item = DispatchWorkItem { [weak self] in
            guard let self, let done = self.items.first(where: { $0.id == t.id }) else { return }
            self.items.removeAll { $0.id == t.id }
            self.work[t.id] = nil
            self.save()
            self.onFinish?(done)
        }
        work[t.id] = item
        // Wall-clock time, so a Mac that slept still ends it on time (or at once, on waking).
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, t.end.timeIntervalSince(now())), execute: item)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(items) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// The real notifications (only inside the app bundle: the unit run has no bundle and leaves the system alone).
    static func systemSchedule(_ id: UUID, _ title: String, _ body: String, _ seconds: Int) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            // The first time, the permission question may take a while: count from the end, not from the answer.
            let seconds = Int(end.timeIntervalSinceNow.rounded())
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(max(seconds, 1)), repeats: false)
            center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: trigger))
        }
    }

    static func systemUnschedule(_ ids: [UUID]) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    }
}

/// Shows Merlin's notifications as banners while Merlin itself is the active app too.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationPresenter()
    static func install() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().delegate = shared
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Carrying it out

/// Runs one fixed action and gives one line to show. Everything it touches is passed in, so the unit run checks every line
/// with fakes. Zero Claude calls.
final class ActionRunner {
    typealias Action = LibraryAssistant.Action

    struct Outcome: Equatable {
        var line: String
        var ok: Bool
    }

    let dock: DockAppStore
    let installed: () -> [DockApp]
    let openApp: (String) -> Bool
    /// Quits the app with that bundle id: false if it is not running.
    let quitApp: (String) -> Bool
    /// One confirmation ("Quit Safari?"): true to go on.
    let confirm: (String) -> Bool
    /// Sends a command to Spotify: false if Spotify is not open (Merlin never launches it).
    let music: (SpotifyCommand) -> Bool
    let currentTrack: () -> SpotifyTrack?
    let isStarred: (SpotifyTrack) -> Bool
    let star: (SpotifyTrack) -> Void
    let timers: TimerStore
    let routines: () -> [Routine]
    let songs: () -> [(name: String, uri: String)]

    init(dock: DockAppStore, installed: @escaping () -> [DockApp], openApp: @escaping (String) -> Bool,
         quitApp: @escaping (String) -> Bool, confirm: @escaping (String) -> Bool, music: @escaping (SpotifyCommand) -> Bool,
         currentTrack: @escaping () -> SpotifyTrack?, isStarred: @escaping (SpotifyTrack) -> Bool,
         star: @escaping (SpotifyTrack) -> Void, timers: TimerStore, routines: @escaping () -> [Routine],
         songs: @escaping () -> [(name: String, uri: String)]) {
        self.dock = dock; self.installed = installed; self.openApp = openApp; self.quitApp = quitApp; self.confirm = confirm
        self.music = music; self.currentTrack = currentTrack; self.isStarred = isStarred; self.star = star
        self.timers = timers; self.routines = routines; self.songs = songs
    }

    /// What the rules match against, now.
    var context: ActionContext { ActionContext(apps: installed(), songs: songs(), routines: routines()) }

    /// The real one: this Mac's apps, Spotify, the system notifications.
    static func live() -> ActionRunner {
        ActionRunner(
            dock: .shared,
            installed: { DockAppStore.shared.installedNow() },
            openApp: { id in
                guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { return false }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
                return true
            },
            quitApp: { id in
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: id)
                guard !running.isEmpty else { return false }
                running.forEach { $0.terminate() }
                return true
            },
            confirm: { question in
                NSApp.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = question
                alert.informativeText = "Unsaved work in that app may ask you to save first."
                // "Cancel" is the Return button; "Quit" needs a click.
                alert.addButton(withTitle: "Cancel")
                let quit = alert.addButton(withTitle: "Quit")
                quit.keyEquivalent = ""
                return alert.runModal() == .alertSecondButtonReturn
            },
            music: { command in
                guard LiveSpotifyBackend().isRunning() else { return false }
                SpotifyService.shared.send(command)
                return true
            },
            currentTrack: {
                // Read now: the dock's Spotify state is only kept fresh while the dock shows.
                let backend = LiveSpotifyBackend()
                guard backend.isRunning(), case .track(let t) = backend.fetch() else { return nil }
                return t
            },
            isStarred: { SpotifySongs.shared.isStarred($0.uri) },
            star: { SpotifySongs.shared.toggleStar($0) },
            timers: .shared,
            routines: { Routine.parse(Settings.shared.routines) },
            songs: { SpotifySongs.shared.songs.map { (name: $0.name, uri: $0.uri) } })
    }

    /// `confirmed`: the one confirmation was given already (the Library Assistant's Apply), so a quit asks no second time.
    func run(_ a: Action, confirmed: Bool = false) -> Outcome {
        if a.type == "routine_run" { return runRoutine(named: a.title ?? "") }
        return step(resolved(a), confirmed: confirmed)
    }

    /// An action that names an app or a song by name only (the Library Assistant's model sends no ids) gets the id here,
    /// from this Mac's apps and the saved songs. Never a guess between two.
    func resolved(_ a: Action) -> Action {
        guard a.key == nil, let name = a.title else { return a }
        var out = a
        switch a.type {
        case "app_open", "app_quit":
            if let app = ActionCommand.findApp(name, in: installed(), exact: false) { out.title = app.name; out.key = app.bundleID }
        case "music_play_song":
            if let song = songs().first(where: { ActionCommand.key($0.name) == ActionCommand.key(name) }) { out.title = song.name; out.key = song.uri }
        default: break
        }
        return out
    }

    private func step(_ a: Action, confirmed: Bool = false) -> Outcome {
        let name = a.title ?? ""
        switch a.type {
        case "dock_add":
            guard let app = ActionCommand.findApp(name, in: installed(), exact: false) else { return fail("No app called “\(name)” on this Mac.") }
            if dock.isPinned(app.bundleID) { return Outcome(line: "\(app.name) is in the dock already.", ok: true) }
            guard dock.canPin else {
                return fail("The dock is full (\(DockAppStore.maxPinned) apps). Say which app to remove first, for example “remove \(dock.pinned.last?.name ?? "Spotify") from the dock”.")
            }
            dock.pin(app)
            return Outcome(line: "Added \(app.name) to the dock", ok: true)
        case "dock_remove":
            guard let app = ActionCommand.findApp(name, in: dock.pinned, exact: false) else { return fail("“\(name)” isn't in the dock.") }
            dock.unpin(app.bundleID)
            return Outcome(line: "Removed \(app.name) from the dock", ok: true)
        case "app_open":
            guard let id = a.key, openApp(id) else { return fail("I couldn't open \(name).") }
            return Outcome(line: "Opened \(name)", ok: true)
        case "app_quit":
            guard let id = a.key else { return fail("I couldn't find \(name).") }
            guard confirmed || confirm("Quit \(name)?") else { return Outcome(line: "Kept \(name) open", ok: false) }
            return quitApp(id) ? Outcome(line: "Quit \(name)", ok: true) : fail("\(name) isn't open.")
        case "music_play": return send(.play, "Playing")
        case "music_pause": return send(.pause, "Paused")
        case "music_next": return send(.next, "Next song")
        case "music_previous": return send(.previous, "Previous song")
        case "music_play_song":
            guard let uri = a.key, SpotifyTrackURI.isValid(uri) else { return fail("That song isn't in your list.") }
            return send(.playTrack(uri), "Playing \(name)")
        case "music_star":
            guard let t = currentTrack(), t.uri != nil else { return fail("No song is playing.") }
            if isStarred(t) { return Outcome(line: "\(t.title) is starred already", ok: true) }
            star(t)
            return Outcome(line: "Starred \(t.title)", ok: true)
        case "timer_start", "reminder_start":
            guard let secs = Int(a.value ?? ""), (1...ActionCommand.maxSeconds).contains(secs) else { return fail("That time isn't one I can set.") }
            let reminder = a.type == "reminder_start"
            timers.start(seconds: secs, label: name, isReminder: reminder)
            let d = ActionCommand.duration(secs)
            return Outcome(line: reminder ? "I'll remind you in \(d)" + (name.isEmpty ? "" : " to \(name)") : "Timer set for \(d)", ok: true)
        case "timer_cancel":
            let n = timers.cancelAll()
            return n == 0 ? fail("No timer is running.") : Outcome(line: n == 1 ? "Cancelled the timer" : "Cancelled \(n) timers", ok: true)
        default:
            return fail("I don't know how to “\(a.type)”.")
        }
    }

    private func send(_ command: SpotifyCommand, _ line: String) -> Outcome {
        music(command) ? Outcome(line: line, ok: true) : fail("Spotify isn't open.")
    }

    private func fail(_ line: String) -> Outcome { Outcome(line: line, ok: false) }

    /// Every step is read first: one step that is not a known action means none of them run. Then in order, stopping at
    /// the first one that fails. A routine never runs another routine.
    private func runRoutine(named name: String) -> Outcome {
        guard let routine = routines().first(where: { ActionCommand.key($0.name) == ActionCommand.key(name) }) else {
            return fail("No routine called “\(name)”.")
        }
        var ctx = context
        ctx.routines = []
        var actions: [Action] = []
        for (i, text) in routine.steps.enumerated() {
            guard let a = ActionCommand.parse(text, context: ctx) else {
                return fail("\(routine.name): step \(i + 1) “\(text)” isn't an action I know. Nothing ran.")
            }
            actions.append(a)
        }
        var done: [String] = []
        for a in actions {
            let out = step(a)
            done.append(out.line.hasSuffix(".") ? String(out.line.dropLast()) : out.line)
            if !out.ok { return Outcome(line: "\(routine.name): " + done.joined(separator: " · ") + ". Stopped there.", ok: false) }
        }
        return Outcome(line: "\(routine.name): " + done.joined(separator: " · "), ok: true)
    }
}
