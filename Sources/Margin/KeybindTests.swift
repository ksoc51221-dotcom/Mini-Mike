import AppKit
import Foundation

extension FeatureTests {
    /// Chords you can change, the Shift-Shift screenshot, and what the chat does with the screenshots.
    static func keybindChecks(_ check: (String, Bool) -> Void) {
        let cmdShift: CGEventFlags = [.maskCommand, .maskShift]
        let d = Keybinds.defaults
        check("keys: defaults are the chords Margin always had",
              d.action(keyCode: 9, flags: cmdShift, tabHeld: false) == .talk && d.action(keyCode: 37, flags: cmdShift, tabHeld: false) == .history
              && d.action(keyCode: 42, flags: [], tabHeld: true) == .snip && d.action(keyCode: 42, flags: [], tabHeld: false) == nil
              && d.action(keyCode: 48, flags: [.maskAlternate, .maskShift], tabHeld: false) == .chat
              && d.action(keyCode: 37, flags: [.maskControl, .maskShift], tabHeld: false) == .engine)
        check("keys: display strings", d.chord(.talk).display == "⇧⌘V" && d.chord(.snip).display == "Tab + \\" && d.chord(.engine).display == "⌃⇧L")

        let suite = UserDefaults(suiteName: "margin.keys.test.\(UUID().uuidString)")!
        let store = KeybindStore(defaults: suite)
        check("keys: a fresh store is the defaults", store.current.isDefault)
        let mine = Chord(keyCode: 38, command: true, option: true) // ⌥⌘J
        check("keys: sets a chord", store.set(mine, for: .history) == nil && store.current.chord(.history) == mine)
        check("keys: the new chord works and the old one is free",
              store.current.action(keyCode: 38, flags: [.maskCommand, .maskAlternate], tabHeld: false) == .history
              && store.current.action(keyCode: 37, flags: cmdShift, tabHeld: false) == nil)
        check("keys: it's kept (a second store reads it)", KeybindStore(defaults: suite).current.chord(.history) == mine)
        check("keys: a chord already in use is refused", store.set(d.chord(.talk), for: .engine) != nil && store.current.chord(.engine) == d.chord(.engine))
        check("keys: a bare key or Shift+key is refused (it would type)",
              store.set(Chord(keyCode: 0), for: .engine) != nil && store.set(Chord(keyCode: 0, shift: true), for: .engine) != nil)
        check("keys: macOS's own chords are refused",
              store.set(Chord(keyCode: 9, command: true), for: .engine) != nil && store.set(Chord(keyCode: 21, command: true, shift: true), for: .engine) != nil)
        check("keys: holding Tab makes a chord usable", store.set(Chord(keyCode: 3, holdTab: true), for: .snip) == nil)
        store.reset(.history)
        check("keys: reset puts one back", store.current.chord(.history) == d.chord(.history) && store.current.chord(.snip).keyCode == 3)
        store.resetAll()
        check("keys: reset all puts everything back", store.current.isDefault)

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
