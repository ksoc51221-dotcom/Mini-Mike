import AppKit

private final class FakeActionWorkspace: DockWorkspace {
    var apps: [DockApp] = []
    func url(forBundleID id: String) -> URL? { URL(fileURLWithPath: "/Applications/\(id).app") }
    func open(_ url: URL) {}
    func installedApps() -> [DockApp] { apps }
    func icon(for url: URL) -> NSImage { NSImage(size: NSSize(width: 1, height: 1)) }
}

extension FeatureTests {
    /// Part C1, the fixed actions: each phrase reads as its action (zero tokens), questions stay questions, the old routes
    /// keep working, the runner's lines are right (the full dock, a quit that asks first, a routine in order), and the Haiku
    /// fallback only ever yields a fixed action. Fakes only: no apps open, no Spotify, no notifications.
    static func actionChecks(_ check: (String, Bool) -> Void) {
        typealias A = LibraryAssistant.Action
        let apps = [DockApp(bundleID: "notion.id", name: "Notion"), DockApp(bundleID: "com.apple.iCal", name: "Calendar"),
                    DockApp(bundleID: "com.apple.dt.Xcode", name: "Xcode"), DockApp(bundleID: "com.apple.Safari", name: "Safari"),
                    DockApp(bundleID: "com.spotify.client", name: "Spotify"), DockApp(bundleID: "com.apple.Notes", name: "Notes"),
                    DockApp(bundleID: "com.apple.mail", name: "Mail"), DockApp(bundleID: "com.apple.Music", name: "Music"),
                    DockApp(bundleID: "com.microsoft.VSCode", name: "Visual Studio Code")]
        let uri = "spotify:track:" + String(repeating: "a", count: 22)
        let routines = Routine.parse("Study time: open Notion; start a 50 minute timer; play\nbroken line\nEnd of day: pause; quit Safari")
        let ctx = ActionContext(apps: apps, songs: [(name: "Blinding Lights", uri: uri)], routines: routines)
        let sheets = ["Physics terms", "Macro note", "Xcode"]
        func r(_ text: String) -> CommandCenter.Route {
            CommandCenter.route(CommandCenter.cleaned(text), sheets: sheets, actions: ctx)
        }
        func act(_ text: String) -> A? { if case .act(let a) = r(text) { return a }; return nil }

        // MARK: Phrases
        check("actions: 'add Calendar to the dock' is dock_add, not a calendar request",
              act("Hey Merlin, add Calendar to the dock.") == A(type: "dock_add", title: "calendar"))
        check("actions: 'add Notion to my dock' / 'put Notion in the rotation' / 'pin Notion to the ring'",
              act("add Notion to my dock")?.type == "dock_add" && act("put Notion in the rotation")?.title == "notion"
              && act("pin the Notion app to the ring")?.title == "notion")
        check("actions: 'remove Spotify from the dock' / 'take Spotify off the dock'",
              act("remove Spotify from the dock") == A(type: "dock_remove", title: "spotify")
              && act("take Spotify off the dock")?.type == "dock_remove" && act("take Spotify out of the dock")?.type == "dock_remove")
        check("actions: 'open Safari' / 'launch Visual Studio Code' / 'open x code' find the app",
              act("open Safari") == A(type: "app_open", title: "Safari", key: "com.apple.Safari")
              && act("launch Visual Studio Code")?.key == "com.microsoft.VSCode" && act("open x code")?.key == "com.apple.dt.Xcode")
        check("actions: 'quit Safari' / 'close the Mail app'",
              act("quit Safari") == A(type: "app_quit", title: "Safari", key: "com.apple.Safari") && act("close the Mail app")?.key == "com.apple.mail")
        check("actions: 'play' / 'pause' / 'next' / 'previous song'",
              act("play")?.type == "music_play" && act("Pause.")?.type == "music_pause" && act("next")?.type == "music_next"
              && act("skip this song")?.type == "music_next" && act("previous song")?.type == "music_previous"
              && act("stop the music")?.type == "music_pause")
        check("actions: 'play Blinding Lights' plays the saved song", act("play blinding lights") == A(type: "music_play_song", title: "Blinding Lights", key: uri))
        check("actions: 'star this song'", act("star this song")?.type == "music_star" && act("like the track")?.type == "music_star")
        check("actions: 'remind me in 25 minutes'", act("remind me in 25 minutes") == A(type: "reminder_start", title: "", value: "1500"))
        check("actions: 'remind me in 1 minute' (checklist step 8)", act("Remind me in 1 minute.") == A(type: "reminder_start", title: "", value: "60"))
        check("actions: 'remind me to stretch in 10 minutes' / 'remind me in an hour to call mum'",
              act("remind me to stretch in 10 minutes") == A(type: "reminder_start", title: "stretch", value: "600")
              && act("remind me in an hour to call mum") == A(type: "reminder_start", title: "call mum", value: "3600"))
        check("actions: 'start a 50 minute timer' / 'set a timer for five minutes' / '25 minute timer' / 'half an hour timer'",
              act("start a 50 minute timer")?.value == "3000" && act("set a timer for five minutes")?.value == "300"
              && act("25 minute timer")?.value == "1500" && act("set a timer for half an hour")?.value == "1800"
              && act("start a twenty five minute timer")?.value == "1500")
        check("actions: 'cancel the timer'", act("cancel the timer")?.type == "timer_cancel" && act("stop my reminders")?.type == "timer_cancel")
        check("actions: a time over 24 hours or of zero is not a timer",
              act("start a 30 hour timer") == nil && act("start a 0 minute timer") == nil)
        check("actions: 'run study time' / 'start my study time routine' / the name alone",
              act("run study time") == A(type: "routine_run", title: "Study time") && act("start my study time routine")?.type == "routine_run"
              && act("study time")?.type == "routine_run")
        check("actions: Settings lines read as routines (a line with no colon is skipped)",
              routines == [Routine(name: "Study time", steps: ["open Notion", "start a 50 minute timer", "play"]),
                           Routine(name: "End of day", steps: ["pause", "quit Safari"])])

        // MARK: Still questions, and the old routes still win
        check("actions: 'what is a dock' stays a question", r("what is a dock") == .ask && r("What is a dock?") == .ask)
        check("actions: questions and other words stay questions",
              r("add 5 and 7") == .ask && r("how do I quit vim") == .ask && r("open the cheat sheet") == .ask
              && r("play a game with me") == .ask && r("quit smoking tips") == .ask && r("can you open Safari") == .ask
              && r("explain how to set a timer in python") == .ask)
        check("actions: 'add lunch to my calendar at 3' is still a calendar request", r("add lunch to my calendar at 3pm tomorrow") == .calendar)
        check("actions: 'add this to my macro note' is still a note command", r("add this to my macro note") == .addToNote("macro"))
        check("actions: 'open Xcode' opens the sheet called Xcode before the app", r("open xcode") == .openNote("xcode"))
        check("actions: 'show my chats' is still the chats list", r("show my chats") == .openChats)
        check("actions: every action route opens no chat", r("pause").isNoteCommand && r("add Notion to the dock").isNoteCommand)

        // MARK: The runner
        let suite = "merlin.actions.test"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let ws = FakeActionWorkspace()
        ws.apps = apps
        d.set(Data("[]".utf8), forKey: DockAppStore.defaultsKey) // an empty dock to start (not the first-run Claude)
        let store = DockAppStore(defaults: d, workspace: ws)
        var scheduled: [(String, Int)] = []
        var unscheduled = 0
        let timers = TimerStore(defaults: d, schedule: { _, _, body, secs in scheduled.append((body, secs)) }, unschedule: { unscheduled += $0.count })
        var log: [String] = []
        var answer = true
        var running: Set<String> = ["com.apple.Safari"]
        var spotifyOpen = true
        var track: SpotifyTrack? = SpotifyTrack(title: "Blinding Lights", artist: "The Weeknd", artworkURL: nil, isPlaying: true, uri: uri)
        var starred = false
        let runner = ActionRunner(
            dock: store, installed: { ws.apps },
            openApp: { log.append("open \($0)"); return true },
            quitApp: { id in log.append("quit \(id)"); return running.remove(id) != nil },
            confirm: { q in log.append("ask \(q)"); return answer },
            music: { c in log.append("music \(c)"); return spotifyOpen },
            currentTrack: { track }, isStarred: { _ in starred }, star: { _ in starred = true },
            timers: timers, routines: { routines }, songs: { [(name: "Blinding Lights", uri: uri)] })

        check("runner: add Calendar to the dock", runner.run(A(type: "dock_add", title: "calendar")).line == "Added Calendar to the dock"
              && store.isPinned("com.apple.iCal"))
        check("runner: adding it twice says so", runner.run(A(type: "dock_add", title: "calendar")).line == "Calendar is in the dock already.")
        check("runner: an app not on this Mac", runner.run(A(type: "dock_add", title: "photoshop")) == .init(line: "No app called “photoshop” on this Mac.", ok: false))
        for name in ["notion", "xcode", "safari", "notes", "mail"] { _ = runner.run(A(type: "dock_add", title: name)) }
        var filler = 0
        while store.canPin { _ = store.pin(DockApp(bundleID: "x.fill\(filler)", name: "Fill\(filler)")); filler += 1 }
        let full = runner.run(A(type: "dock_add", title: "music"))
        check("runner: at 20 apps it says which to remove, and adds nothing",
              !full.ok && full.line.hasPrefix("The dock is full (20 apps). Say which app to remove first") && !store.isPinned("com.apple.Music")
              && store.pinned.count == 20)
        for i in 0..<filler { store.unpin("x.fill\(i)") }
        check("runner: remove Mail from the dock", runner.run(A(type: "dock_remove", title: "mail")).line == "Removed Mail from the dock" && !store.isPinned("com.apple.mail"))
        check("runner: removing an app not in the dock", !runner.run(A(type: "dock_remove", title: "spotify")).ok)
        log = []
        answer = false
        let kept = runner.run(A(type: "app_quit", title: "Safari", key: "com.apple.Safari"))
        check("runner: quit asks once first; No keeps the app open", kept.line == "Kept Safari open" && log == ["ask Quit Safari?"])
        answer = true
        log = []
        check("runner: Yes quits it", runner.run(A(type: "app_quit", title: "Safari", key: "com.apple.Safari")).line == "Quit Safari"
              && log == ["ask Quit Safari?", "quit com.apple.Safari"])
        check("runner: the Library Assistant's Apply counts as the confirmation, and a name alone finds the app",
              { log = []; running.insert("com.apple.Safari"); return runner.run(A(type: "app_quit", title: "safari"), confirmed: true).line == "Quit Safari" && log == ["quit com.apple.Safari"] }())
        check("runner: open Notion", runner.run(A(type: "app_open", title: "Notion", key: "notion.id")).line == "Opened Notion")
        log = []
        check("runner: play / pause / next send explicit commands (not the toggle)",
              runner.run(A(type: "music_play")).line == "Playing" && runner.run(A(type: "music_pause")).line == "Paused"
              && runner.run(A(type: "music_next")).line == "Next song" && log == ["music play", "music pause", "music next"])
        check("runner: a saved song plays by its URI", { log = []; return runner.run(A(type: "music_play_song", title: "Blinding Lights", key: uri)).line == "Playing Blinding Lights" && log == ["music playTrack(\"\(uri)\")"] }())
        check("runner: a bad URI sends nothing", { log = []; return !runner.run(A(type: "music_play_song", title: "x", key: "spotify:track:bad")).ok && log.isEmpty }())
        spotifyOpen = false
        check("runner: Spotify closed", runner.run(A(type: "music_play")) == .init(line: "Spotify isn't open.", ok: false))
        spotifyOpen = true
        check("runner: star this song, then again", runner.run(A(type: "music_star")).line == "Starred Blinding Lights" && starred
              && runner.run(A(type: "music_star")).line == "Blinding Lights is starred already")
        track = nil
        check("runner: star with no song playing", !runner.run(A(type: "music_star")).ok)
        check("runner: a reminder is scheduled with the system", runner.run(A(type: "reminder_start", title: "", value: "60")).line == "I'll remind you in 1 min"
              && scheduled.last?.1 == 60 && timers.items.count == 1 && timers.next?.isReminder == true)
        check("runner: a timer", runner.run(A(type: "timer_start", value: "3000")).line == "Timer set for 50 min" && timers.items.count == 2)
        check("runner: timers are saved for a restart", TimerStore(defaults: d, schedule: { _, _, _, _ in }, unschedule: { _ in }).items.count == 2)
        check("runner: cancel stops them all", runner.run(A(type: "timer_cancel")).line == "Cancelled 2 timers" && unscheduled == 2 && timers.items.isEmpty)
        check("runner: cancel with none", !runner.run(A(type: "timer_cancel")).ok)

        // MARK: Routines
        log = []
        let study = runner.run(A(type: "routine_run", title: "study time"))
        check("routine: runs its actions in order", study.ok && study.line == "Study time: Opened Notion · Timer set for 50 min · Playing"
              && log == ["open notion.id", "music play"] && timers.items.count == 1)
        _ = timers.cancelAll()
        log = []
        spotifyOpen = false
        let stopped = runner.run(A(type: "routine_run", title: "End of day"))
        check("routine: stops at the first step that fails", !stopped.ok && stopped.line == "End of day: Spotify isn't open. Stopped there."
              && !log.contains { $0.hasPrefix("ask") })
        spotifyOpen = true
        let bad = ActionRunner(dock: store, installed: { apps }, openApp: { log.append("open \($0)"); return true }, quitApp: { _ in true },
                               confirm: { _ in true }, music: { _ in log.append("music"); return true }, currentTrack: { nil },
                               isStarred: { _ in false }, star: { _ in }, timers: timers,
                               routines: { Routine.parse("Morning: play; dance wildly; open Notion") }, songs: { [] })
        log = []
        let refused = bad.run(A(type: "routine_run", title: "morning"))
        check("routine: one unknown step means nothing runs", !refused.ok && refused.line.contains("step 2 “dance wildly”") && log.isEmpty)

        check("actions: 'add Notion to my doc' (dictation) is the dock, 'add this to my doc' is not",
              act("add Notion to my doc") == A(type: "dock_add", title: "notion") && act("add this to my doc") == nil)

        // MARK: Library Assistant (the same list)
        check("assistant: quit needs one confirmation; the other actions are safe",
              LibraryAssistant.risk(of: A(type: "app_quit")) == .confirm && LibraryAssistant.risk(of: A(type: "dock_add")) == .safe
              && LibraryAssistant.risk(of: A(type: "timer_start")) == .safe)
    }
}
