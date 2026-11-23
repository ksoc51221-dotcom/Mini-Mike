import AppKit
import Foundation

extension FeatureTests {
    /// Chords you can change, the Shift-Shift screenshot, and what the chat does with the screenshots.
    static func keybindChecks(_ check: (String, Bool) -> Void) {
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let d = Keybinds.defaults
        check("keys: defaults are the chords Merlin always had",
              d.action(keyCode: 12, flags: [], tabHeld: true) == .talk && d.action(keyCode: 37, flags: cmdShift, tabHeld: false) == .history
              && d.action(keyCode: 42, flags: [], tabHeld: true) == .snip && d.action(keyCode: 42, flags: [], tabHeld: false) == nil
              && d.action(keyCode: 48, flags: [.maskAlternate, .maskShift], tabHeld: false) == .chat
              && d.action(keyCode: 37, flags: [.maskControl, .maskShift], tabHeld: false) == .engine)
        check("keys: display strings", d.chord(.talk).display == "Tab + Q" && d.chord(.snip).display == "Tab + \\" && d.chord(.engine).display == "⌃⇧L")

        // A throwaway in-memory store: nothing here touches your saved shortcuts or any file.
        let store = KeybindStore(memory: nil)
        check("keys: a fresh store is the defaults", store.current.isDefault)
        let mine = Chord(keyCode: 38, command: true, option: true) // ⌥⌘J
        check("keys: sets a chord", store.set(mine, for: .history) == nil && store.current.chord(.history) == mine)
        check("keys: the new chord works and the old one is free",
              store.current.action(keyCode: 38, flags: [.maskCommand, .maskAlternate], tabHeld: false) == .history
              && store.current.action(keyCode: 37, flags: cmdShift, tabHeld: false) == nil)
        check("keys: it's kept (a second store reads it)", KeybindStore(memory: store.saved).current.chord(.history) == mine)
        check("keys: a bare key or Shift+key is refused (it would type)",
              store.set(Chord(keyCode: 0), for: .engine) != nil && store.set(Chord(keyCode: 0, shift: true), for: .engine) != nil
              && store.current.chord(.engine) == d.chord(.engine))
        check("keys: holding Tab makes a chord usable", store.set(Chord(keyCode: 3, holdTab: true), for: .snip) == nil)
        store.reset(.history)
        check("keys: reset puts one back", store.current.chord(.history) == d.chord(.history) && store.current.chord(.snip).keyCode == 3)
        store.resetAll()
        check("keys: reset all puts everything back", store.current.isDefault)
        keybindCommandChecks(check)
        MainActor.assumeIsolated { shortcutPageChecks(check) }

        // Tap Shift twice.
        var t = DoubleShift()
        func tap(at time: TimeInterval) -> Bool {
            let down = t.flagsChanged(shift: true, others: false, at: time)
            _ = t.flagsChanged(shift: false, others: false, at: time + 0.05)
            return down
        }
        check("shift: two taps inside a second fire on the second", tap(at: 10) == false && tap(at: 10.4) == true)
        check("shift: a third tap doesn't fire again", tap(at: 10.7) == false)
        t = DoubleShift()
        check("shift: slow taps don't", tap(at: 20) == false && tap(at: 21.5) == false)
        t = DoubleShift()
        _ = tap(at: 30); t.interrupt()
        check("shift: a typed key or click in between cancels it", tap(at: 30.3) == false)
        t = DoubleShift()
        _ = tap(at: 40)
        check("shift: Shift with ⌘ held is a shortcut, not a tap", t.flagsChanged(shift: true, others: true, at: 40.2) == false && tap(at: 40.3) == false)
        t = DoubleShift()
        check("shift: holding Shift down is one press", t.flagsChanged(shift: true, others: false, at: 50) == false
              && t.flagsChanged(shift: true, others: false, at: 50.2) == false)

        // Screenshots in the chat.
        let model = AskModel(selection: Selection(text: "x", appName: "Test", context: ContextBox(resolved: nil), pid: 0, mouse: .zero), footnote: "")
        var sent: [String] = []
        model.onAsk = { sent.append($0) }
        model.attachments = [.init(data: Data([1, 2, 3]), thumb: nil)]
        model.draft = ""
        model.submit()
        check("shot: return with only a screenshot asks about it", sent == [Prompts.aboutScreenshot] && model.turns.last?.question.hasSuffix("with screenshot") == true)
        check("shot: the chat never sends more than three", AskModel.maxAttachments == 3)
    }
}

extension FeatureTests {
    /// The command list, the conflict rule, saving and resetting with clashes, fixed chords, and what the status menu shows.
    static func keybindCommandChecks(_ check: (String, Bool) -> Void) {
        let all = ShortcutCommand.all
        let d = Keybinds.defaults
        let cmd = Chord(keyCode: 38, command: true)           // ⌘J
        let other = Chord(keyCode: 40, command: true, shift: true) // ⌘⇧K

        // The list.
        check("commands: every command has its own id, name and default chord",
              Set(all.map(\.id)).count == all.count && Set(all.map(\.title)).count == all.count
              && Set(all.map { "\($0.defaultChord.keyCode)-\($0.defaultChord.display)" }).count == all.count
              && all.allSatisfy { !$0.title.isEmpty && !$0.detail.isEmpty })
        check("commands: the five first anywhere shortcuts keep the ids and chords they always had (the edge panel's is sixth)",
              ShortcutCommand.inScope(.global).map(\.id) == ["snip", "chat", "talk", "history", "engine", "edgePanel"]
              && d.chord(.edgePanel) == Chord(keyCode: 30, holdTab: true) && d.chord(.edgePanel).display == "Tab + ]"
              && d.action(keyCode: 30, flags: [], tabHeld: true) == .edgePanel && d.action(keyCode: 30, flags: [], tabHeld: false) == nil
              && d.chord(.snip) == Chord(keyCode: 42, holdTab: true) && d.chord(.chat) == Chord(keyCode: 48, shift: true, option: true)
              && d.chord(.talk) == Chord(keyCode: 12, holdTab: true) && d.chord(.history) == Chord(keyCode: 37, command: true, shift: true)
              && d.chord(.engine) == Chord(keyCode: 37, shift: true, control: true))
        check("commands: the Library ones start on the keys they always had",
              d.chord(.libraryNewChat).display == "⌘N" && d.chord(.librarySearch).display == "⌘K" && d.chord(.librarySearchAlt).display == "⌘F"
              && d.chord(.libraryMove).display == "⇧⌘M" && d.chord(.libraryBin).display == "⌘⌫")
        check("commands: globals come first in the list (they win a clash)",
              all.prefix(6).allSatisfy { $0.scope == .global } && all.dropFirst(6).allSatisfy { $0.scope != .global })
        check("commands: the defaults don't clash with each other or with a fixed chord", d.conflicting.isEmpty)
        check("commands: every default can be used (usable, and a window one maps to a SwiftUI key)",
              all.allSatisfy { Keybinds.problem($0.defaultChord, for: $0) == nil })

        // The one conflict rule, for every pair of scopes.
        let a = Chord(keyCode: 5, command: true), b = Chord(keyCode: 6, command: true)
        let want: [(ShortcutScope, ShortcutScope, Bool)] = [
            (.global, .global, true), (.global, .chat, true), (.global, .library, true),
            (.chat, .global, true), (.chat, .chat, true), (.chat, .library, false),
            (.library, .global, true), (.library, .chat, false), (.library, .library, true),
        ]
        for (x, y, expected) in want {
            check("conflict rule: the same chord, \(x.rawValue) and \(y.rawValue) → \(expected ? "clash" : "no clash")",
                  Keybinds.clash(a, in: x, a, in: y) == expected)
            check("conflict rule: different chords never clash (\(x.rawValue), \(y.rawValue))", !Keybinds.clash(a, in: x, b, in: y))
        }
        check("conflict rule: hold-Tab is part of the chord", !Keybinds.clash(Chord(keyCode: 5, holdTab: true), in: .global, Chord(keyCode: 5), in: .global))

        // Old saved data still loads, exactly as it was written before this change.
        let old = #"{"chords":{"snip":{"keyCode":42,"command":false,"shift":false,"option":false,"control":false,"holdTab":true},"chat":{"keyCode":48,"command":false,"shift":true,"option":true,"control":false,"holdTab":false},"talk":{"keyCode":9,"command":true,"shift":true,"option":false,"control":false,"holdTab":false},"history":{"keyCode":38,"command":true,"shift":false,"option":true,"control":false,"holdTab":false},"engine":{"keyCode":37,"command":false,"shift":true,"option":false,"control":true,"holdTab":false}},"doubleShift":false}"#
        let loaded = KeybindStore(memory: old.data(using: .utf8)).current
        check("saved format: today's JSON loads unchanged", loaded.chord(.history) == Chord(keyCode: 38, command: true, option: true)
              && loaded.chord(.snip) == d.chord(.snip) && loaded.chord(.engine) == d.chord(.engine) && loaded.doubleShift == false)
        check("saved format: commands it doesn't know take their defaults", loaded.chord(.libraryBin) == d.chord(.libraryBin)
              && loaded.chord(.libraryNewChat) == d.chord(.libraryNewChat) && loaded.chords.count == all.count)
        let extra = #"{"chords":{"history":{"keyCode":38,"command":true,"shift":false,"option":true,"control":false,"holdTab":false},"gone.command":{"keyCode":1}},"doubleShift":true}"#
        check("saved format: an unknown id is dropped, not an error", KeybindStore(memory: extra.data(using: .utf8)).current.chords["gone.command"] == nil)
        check("saved format: unreadable data falls back to the defaults", KeybindStore(memory: Data("nope".utf8)).current.isDefault)
        let round = KeybindStore(memory: nil)
        round.set(cmd, for: .libraryMove)
        let json = String(data: round.saved ?? Data(), encoding: .utf8) ?? ""
        check("saved format: still {chords, doubleShift}, keyed by command id",
              json.contains("\"chords\"") && json.contains("\"doubleShift\"") && json.contains("\"library.move\"") && KeybindStore(memory: round.saved).current.chord(.libraryMove) == cmd)

        // Set, clash, resolve.
        let s = KeybindStore(memory: nil)
        check("clash: nothing at first", s.current.conflicting.isEmpty)
        check("clash: a chord another command uses is saved, not refused", s.set(d.chord(.talk), for: .engine) == nil && s.current.chord(.engine) == d.chord(.talk))
        var now = s.current
        check("clash: both rows are marked, each pointing at the other",
              now.rivals(of: .talk) == [.engine] && now.rivals(of: .engine) == [.talk] && now.conflicting == [.talk, .engine])
        check("clash: the first in the list is the one that fires",
              now.effectiveChord(for: .talk) == d.chord(.talk) && now.effectiveChord(for: .engine) == nil
              && now.action(keyCode: 12, flags: [], tabHeld: true) == .talk)
        s.set(cmd, for: .engine)
        now = s.current
        check("clash: moving one away clears both", now.conflicting.isEmpty && now.effectiveChord(for: .engine) == cmd)
        // A global chord reaches into every window; a Library one doesn't reach into the chat.
        s.set(d.chord(.history), for: .libraryNewChat)
        now = s.current
        check("clash: a Library command on a global chord clashes, and the global one fires",
              now.rivals(of: .libraryNewChat) == [.history] && now.effectiveChord(for: .libraryNewChat) == nil && now.effectiveChord(for: .history) == d.chord(.history))
        s.reset(.libraryNewChat)
        check("clash: reset clears it", s.current.conflicting.isEmpty)
        let trio = Chord(keyCode: 32, command: true, option: true) // ⌥⌘U
        s.set(trio, for: .libraryMove)
        s.set(trio, for: .libraryBin)
        check("clash: two Library commands on one chord: first in the list fires, the other is silent",
              s.current.effectiveChord(for: .libraryMove) == trio && s.current.effectiveChord(for: .libraryBin) == nil)
        s.set(trio, for: .snip) // a global on the same keys: now three-way, and the global fires
        check("clash: three on one chord: only the first listed (the global) fires",
              s.current.rivals(of: .snip).count == 2 && s.current.effectiveChord(for: .snip) == trio
              && s.current.effectiveChord(for: .libraryMove) == nil && s.current.effectiveChord(for: .libraryBin) == nil)
        s.resetAll()
        check("clash: reset all clears every clash", s.current.conflicting.isEmpty && s.current.isDefault)

        // A reset that creates a clash.
        let r = KeybindStore(memory: nil)
        r.set(other, for: .talk)                  // talk moves away from Tab + Q
        r.set(d.chord(.talk), for: .engine)       // engine takes Tab + Q: free, so no clash
        check("reset clash: moving talk away first leaves no clash", r.current.conflicting.isEmpty)
        r.reset(.talk)                            // talk goes home to Tab + Q, which engine now has
        check("reset clash: resetting one onto a chord another now uses shows the clash on both",
              Set(r.current.conflicting.map(\.id)) == ["talk", "engine"] && r.current.rivals(of: .talk) == [.engine])
        r.reset(.engine)
        check("reset clash: resetting the other clears it", r.current.conflicting.isEmpty)

        // Chords that can never work are refused; nothing changes.
        let u = KeybindStore(memory: nil)
        let before = u.current
        let refused: [(String, Chord, ShortcutCommand)] = [
            ("no modifier, global", Chord(keyCode: 0), .history), ("Shift only, global", Chord(keyCode: 0, shift: true), .history),
            ("no modifier, Library", Chord(keyCode: 0), .libraryMove), ("Shift only, Library", Chord(keyCode: 0, shift: true), .libraryMove),
            ("a lone modifier key", Chord(keyCode: 55, command: true), .history), ("a lone Shift", Chord(keyCode: 56, shift: true), .libraryMove),
            ("hold-Tab on a Library command", Chord(keyCode: 42, holdTab: true), .libraryMove),
            ("an F-key in a window", Chord(keyCode: 122, command: true), .libraryMove),
        ]
        for (name, chord, command) in refused {
            check("unusable: \(name) is refused with a reason", u.set(chord, for: command) != nil && u.current == before)
        }
        check("unusable: hold-Tab is fine on a global one, an F-key too",
              u.set(Chord(keyCode: 3, holdTab: true), for: .snip) == nil && u.set(Chord(keyCode: 122, command: true), for: .history) == nil)

        // Fixed chords are flagged, not refused.
        let fixedNames: [(String, Chord, String)] = [
            ("⌘C", Chord(keyCode: 8, command: true), "macOS for Copy"), ("⌘V", Chord(keyCode: 9, command: true), "macOS for Paste"),
            ("⌘Q", Chord(keyCode: 12, command: true), "macOS for Quit"), ("⌘W", Chord(keyCode: 13, command: true), "macOS for Close Window"),
            ("⌘⇧4", Chord(keyCode: 21, command: true, shift: true), "macOS for Screenshots"),
            ("Esc", Chord(keyCode: 53), "Merlin for closing or cancelling"), ("Return", Chord(keyCode: 36), "Merlin for Send"),
        ]
        for (name, chord, thing) in fixedNames {
            check("fixed chords: \(name) is known as '\(thing)'", Keybinds.fixedUse(of: chord) == thing)
        }
        let f = KeybindStore(memory: nil)
        check("fixed chords: saved anyway and the row is flagged",
              f.set(Chord(keyCode: 8, command: true), for: .libraryMove) == nil
              && f.current.clash(of: .libraryMove).fixedUse == "macOS for Copy" && f.current.conflicting == [.libraryMove])
        f.set(Chord(keyCode: 12, command: true), for: .history)
        check("fixed chords: counted with the clashes in the summary", f.current.conflicting == [.history, .libraryMove])
        f.reset(.libraryMove)
        f.reset(.history)
        check("fixed chords: reset clears the flag", f.current.conflicting.isEmpty)
        check("fixed chords: a default is never flagged (⌘F, ⌘N and ⌘K are Merlin's own)", Keybinds.fixedUse(of: d.chord(.librarySearchAlt)) == nil
              && Keybinds.fixedUse(of: d.chord(.libraryNewChat)) == nil)

        // Window shortcuts: only the winner is attached, and only a chord SwiftUI can name.
        check("window keys: a SwiftUI shortcut is built from the chord",
              d.chord(.libraryMove).keyboardShortcut != nil && d.chord(.libraryBin).keyboardShortcut != nil
              && Chord(keyCode: 42, holdTab: true).keyboardShortcut == nil && Chord(keyCode: 122, command: true).keyboardShortcut == nil)

        // ⌘, and ⌘[ are Library commands now (open the settings, back to the Library), not hard-coded keys.
        check("commands: 'Open settings' (⌘,) and 'Back to the Library' (⌘[) are Library commands",
              d.chord(.libraryOpenSettings).display == "⌘," && d.chord(.libraryBack).display == "⌘[" && all.count == 13
              && ShortcutCommand.libraryOpenSettings.scope == .library && ShortcutCommand.libraryBack.scope == .library
              && d.chord(.libraryOpenSettings).keyboardShortcut != nil && d.chord(.libraryBack).keyboardShortcut != nil)
        check("commands: ⌘, is theirs now, not 'macOS for Settings'", Keybinds.fixedUse(of: d.chord(.libraryOpenSettings)) == nil)
        let w = KeybindStore(memory: nil)
        w.set(d.chord(.libraryBack), for: .libraryMove) // ⌘[ onto "Move to a sector"
        check("commands: binding something to ⌘[ clashes with 'Back to the Library', both red",
              Set(w.current.conflicting.map(\.id)) == ["library.move", "library.back"] && w.current.rivals(of: .libraryBack) == [.libraryMove])
        check("commands: the first listed fires; ⌘[ stays the move command's, 'Back' goes quiet",
              w.current.effectiveChord(for: .libraryMove) == d.chord(.libraryBack) && w.current.effectiveChord(for: .libraryBack) == nil)
        w.reset(.libraryMove)
        w.set(d.chord(.libraryOpenSettings), for: .libraryBin) // ⌘, onto the Bin
        check("commands: binding something to ⌘, clashes with 'Open settings'",
              w.current.rivals(of: .libraryOpenSettings) == [.libraryBin] && w.current.conflicting.count == 2)
        w.resetAll()
        check("commands: reset clears both", w.current.conflicting.isEmpty)
        let both = KeybindStore(memory: nil)
        both.set(d.chord(.libraryBack), for: .libraryOpenSettings) // swapping their keys by hand
        check("commands: 'Open settings' on ⌘[ clashes with 'Back'", both.current.rivals(of: .libraryBack) == [.libraryOpenSettings])

        // The status menu follows the store.
        let item = NSMenuItem(title: "x", action: nil, keyEquivalent: "")
        StatusMenu.showShortcut(d.chord(.chat), on: item)
        check("status menu: the defaults show as they always did", item.keyEquivalent == "\t" && item.keyEquivalentModifierMask == [.option, .shift])
        StatusMenu.showShortcut(d.chord(.history), on: item)
        check("status menu: Library shows ⌘⇧L", item.keyEquivalent == "l" && item.keyEquivalentModifierMask == [.command, .shift])
        let m = KeybindStore(memory: nil)
        m.set(Chord(keyCode: 38, command: true, option: true), for: .history)
        StatusMenu.showShortcut(m.current.chord(.history), on: item)
        check("status menu: a changed chord is what the menu shows", item.keyEquivalent == "j" && item.keyEquivalentModifierMask == [.command, .option])
        StatusMenu.showShortcut(Chord(keyCode: 42, holdTab: true), on: item)
        check("status menu: a hold-Tab chord leaves the item bare (a menu can't show it)", item.keyEquivalent == "" && item.keyEquivalentModifierMask.isEmpty)
        check("status menu: the snip and voice lines follow the store",
              StatusMenu.snipTitle(d) == "Snip & Ask…   (hold Tab, press \\)" && StatusMenu.talkTitle(d) == "Voice: hold Tab + Q to talk"
              && StatusMenu.talkTitle(m.current) == StatusMenu.talkTitle(d)
              && { m.set(Chord(keyCode: 38, command: true, option: true), for: .talk); return StatusMenu.talkTitle(m.current) == "Voice: hold ⌥⌘J to talk" }()
              && { m.set(Chord(keyCode: 3, holdTab: true), for: .snip); return StatusMenu.snipTitle(m.current) == "Snip & Ask…   (hold Tab, press F)" }())
    }
}

