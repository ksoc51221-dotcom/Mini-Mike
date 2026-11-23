import AppKit
import Foundation

/// A test copy of the event tap: its own shortcuts, a fake clock, fake held keys, and a timer you fire by hand.
/// Nothing here reads the real keyboard or waits for real time.
private final class FakeTap {
    let keys = Hotkeys()
    var time: TimeInterval = 100
    var held: Set<Int64> = []
    var tab = false
    var pointOn = true
    var pointKeys: Set<Int64> = [56, 60]
    var timers: [() -> Void] = []
    var log: [String] = []
    var mouse = CGPoint(x: 500, y: 400)

    init(store: KeybindStore = KeybindStore(memory: nil)) {
        keys.store = store
        keys.now = { [unowned self] in time }
        keys.modifiersHeld = { [unowned self] in held }
        keys.tabHeld = { [unowned self] in tab }
        keys.pointer = { [unowned self] in mouse }
        keys.pointSettings = { [unowned self] in (pointOn, pointKeys) }
        keys.schedule = { [unowned self] _, work in timers.append(work) }
        keys.onTalkStart = { [unowned self] in log.append("talk") }
        keys.onTalkEnd = { [unowned self] in log.append("end") }
        keys.onTalkCancel = { [unowned self] in log.append("cancel") }
        keys.onPointStart = { [unowned self] _, _ in log.append("point") }
        keys.onPointMove = { [unowned self] _ in if log.last != "move" { log.append("move") } }
        keys.onPointCancel = { [unowned self] in log.append("point-cancel") }
        keys.onPointEnd = { [unowned self] withTalk in log.append(withTalk ? "ask+talk" : "ask") }
        keys.onDoubleShift = { [unowned self] in log.append("double") }
    }

    /// Lets the main-queue callbacks run.
    private func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }

    /// A modifier key goes down or up (`held` follows). Returns true when the event was swallowed.
    @discardableResult
    func modifier(_ code: Int64, down: Bool, at t: TimeInterval? = nil) -> Bool {
        if let t { time = t }
        if down { held.insert(code) } else { held.remove(code) }
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(code), keyDown: down) else { return false }
        e.flags = ModifierKeys.flags(held)
        e.location = mouse
        let swallowed = keys.handle(.flagsChanged, e) == nil
        settle()
        return swallowed
    }

    /// A normal key, with whatever modifiers are held. Returns true when it was swallowed.
    @discardableResult
    func key(_ code: CGKeyCode, down: Bool, repeating: Bool = false, at t: TimeInterval? = nil) -> Bool {
        if let t { time = t }
        if code == 48 { tab = down }
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { return false }
        e.flags = ModifierKeys.flags(held)
        if repeating { e.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        let swallowed = keys.handle(down ? .keyDown : .keyUp, e) == nil
        settle()
        return swallowed
    }

    /// The pointer moves to `p`.
    func move(to p: CGPoint, at t: TimeInterval) {
        time = t
        mouse = p
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left) else { return }
        _ = keys.handle(.mouseMoved, e)
        settle()
    }

    /// A click (or a scroll). Returns true when it was swallowed.
    @discardableResult
    func click(_ type: CGEventType = .leftMouseDown) -> Bool {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: mouse, mouseButton: .left) else { return false }
        let swallowed = keys.handle(type, e) == nil
        settle()
        return swallowed
    }

    /// The talk timer fires at `t`.
    func fire(at t: TimeInterval) {
        time = t
        let due = timers
        timers = []
        due.forEach { $0() }
        settle()
    }

    func take() -> [String] { defer { log = [] }; return log }

    /// A click with nothing held, between two made-up gestures: the double-Shift timer runs on real time, so two
    /// gestures a few milliseconds apart would otherwise read as a double tap.
    func gap() { click(); log = [] }
}

extension FeatureTests {
    /// The talk key: Tab + Q by default, the one-time move from ⌘⇧V, and talk on one modifier key held on its own.
    static func talkKeyChecks(_ check: (String, Bool) -> Void) {
        let tabQ = Chord(keyCode: 12, holdTab: true)
        let oldV = Chord(keyCode: 9, command: true, shift: true)
        let optCmdJ = Chord(keyCode: 38, command: true, option: true)
        check("talk key: the default is Tab + Q", Keybinds.defaults.chord(.talk) == tabQ && ShortcutCommand.talk.defaultChord.display == "Tab + Q")

        // The one-time move. The JSON strings are exactly what older versions saved (no marker, no modifierKey).
        func chordJSON(_ code: Int, cmd: Bool = false, shift: Bool = false, opt: Bool = false) -> String {
            #"{"keyCode":\#(code),"command":\#(cmd),"shift":\#(shift),"option":\#(opt),"control":false,"holdTab":false}"#
        }
        let absent = #"{"chords":{"history":"# + chordJSON(38, cmd: true, opt: true) + #"},"doubleShift":true}"#
        let onOld = #"{"chords":{"talk":"# + chordJSON(9, cmd: true, shift: true) + #","history":"# + chordJSON(37, cmd: true, shift: true) + #"},"doubleShift":false}"#
        let custom = #"{"chords":{"talk":"# + chordJSON(38, cmd: true, opt: true) + #"},"doubleShift":true}"#
        let loadedAbsent = KeybindStore(memory: absent.data(using: .utf8)).current
        check("migration: old saved data still loads", loadedAbsent.chord(.history) == optCmdJ && loadedAbsent.doubleShift)
        check("migration: talk not saved → Tab + Q", loadedAbsent.chord(.talk) == tabQ)
        let fromOld = KeybindStore(memory: onOld.data(using: .utf8))
        check("migration: talk saved on ⌘⇧V → Tab + Q", fromOld.current.chord(.talk) == tabQ && fromOld.current.doubleShift == false)
        check("migration: a talk key you picked is kept", KeybindStore(memory: custom.data(using: .utf8)).current.chord(.talk) == optCmdJ)
        check("migration: the moved store counts as the defaults (nothing else changed)",
              KeybindStore(memory: #"{"chords":{},"doubleShift":true}"#.data(using: .utf8)).current.isDefault)
        fromOld.set(Chord(keyCode: 4, command: true, option: true), for: .history) // any change saves, with the marker
        let savedOnce = String(data: fromOld.saved ?? Data(), encoding: .utf8) ?? ""
        check("migration: the next save writes the marker", savedOnce.contains("\"talkMoved\":true")
              && KeybindStore(memory: fromOld.saved).current.chord(.talk) == tabQ)
        check("migration: after the move, picking ⌘⇧V on purpose is kept", fromOld.set(oldV, for: .talk) == nil
              && KeybindStore(memory: fromOld.saved).current.chord(.talk) == oldV
              && KeybindStore(memory: KeybindStore(memory: fromOld.saved).saved).current.chord(.talk) == oldV)
        check("migration: a chord saved before still decodes (no modifierKey field)",
              (try? JSONDecoder().decode(Chord.self, from: Data(chordJSON(12).utf8)))?.modifierKey == nil)

        // Modifier-only chords.
        let rightCtrl = Chord.modifierOnly(62)
        check("modifier key: names tell left from right", rightCtrl.display == "Right ⌃" && Chord.modifierOnly(58).display == "Left ⌥"
              && Chord.modifierOnly(63).display == "Fn" && Chord.modifierOnly(54).display == "Right ⌘" && Chord.modifierOnly(56).display == "Left ⇧")
        check("modifier key: left and right are different chords", Chord.modifierOnly(59) != Chord.modifierOnly(62))
        check("modifier key: it saves and loads", (try? JSONDecoder().decode(Chord.self, from: JSONEncoder().encode(rightCtrl))) == rightCtrl)
        check("modifier key: no menu or window shortcut can show it", rightCtrl.keyboardShortcut == nil && rightCtrl.menuEquivalent == nil)
        check("modifier key: it never matches a keyDown (Control+C, Control+A stay normal)",
              !rightCtrl.matches(keyCode: 8, flags: .maskControl, tabHeld: false) && !rightCtrl.matches(keyCode: -1, flags: .maskControl, tabHeld: false)
              && !rightCtrl.matches(keyCode: 62, flags: .maskControl, tabHeld: false))
        check("problem: a lone modifier is fine for talk", Keybinds.problem(rightCtrl, for: .talk) == nil
              && Keybinds.problem(.modifierOnly(63), for: .talk) == nil && Keybinds.problem(.modifierOnly(58), for: .talk) == nil)
        check("problem: refused for every other command", ShortcutCommand.all.filter { $0.id != "talk" }.allSatisfy { Keybinds.problem(rightCtrl, for: $0) != nil })
        check("problem: Shift and Caps Lock alone are refused for talk", Keybinds.problem(.modifierOnly(56), for: .talk) != nil
              && Keybinds.problem(.modifierOnly(60), for: .talk) != nil && Keybinds.problem(.modifierOnly(57), for: .talk) != nil)
        let m = KeybindStore(memory: nil)
        check("modifier key: set for talk, it's no keyDown action and no clash", m.set(rightCtrl, for: .talk) == nil
              && m.current.chord(.talk) == rightCtrl && m.current.conflicting.isEmpty
              && m.current.action(keyCode: 8, flags: .maskControl, tabHeld: false) == nil
              && StatusMenu.talkTitle(m.current) == "Voice: hold Right ⌃ to talk")
        check("modifier key: refused for the Library shortcut, nothing changes", m.set(rightCtrl, for: .history) != nil && m.current.chord(.history) == Keybinds.defaults.chord(.history))

        // The rule itself, with made-up times.
        var h = ModifierHold(keys: [62], delay: 0.15)
        _ = h.modifiers([62], at: 0)
        check("hold: nothing before 150 ms", h.tick(at: 0.10) == .none && h.phase == .pending)
        check("hold: starts at 150 ms", h.tick(at: 0.15) == .start && h.isActive)
        check("hold: letting go ends it (send)", h.modifiers([], at: 0.9) == .end && h.phase == .idle)
        _ = h.modifiers([62], at: 1)
        check("hold: another key before 150 ms drops it silently", h.interrupt() == .none && h.tick(at: 1.2) == .none && h.phase == .idle)
        check("hold: and nothing restarts until the key is let go", h.modifiers([62, 56], at: 1.3) == .none && h.modifiers([62], at: 1.35) == .none
              && h.tick(at: 1.6) == .none)
        _ = h.modifiers([], at: 2)
        _ = h.modifiers([62], at: 3)
        _ = h.tick(at: 3.2)
        check("hold: after start another key cancels", h.interrupt() == .cancel && h.phase == .idle && h.modifiers([], at: 3.5) == .none)
        _ = h.modifiers([62], at: 4)
        check("hold: another modifier before 150 ms drops it", h.modifiers([62, 59], at: 4.05) == .none && h.tick(at: 4.3) == .none)
        _ = h.modifiers([], at: 5)
        _ = h.modifiers([59], at: 5.1) // Left ⌃ is a different key
        check("hold: the other side's key doesn't count", h.tick(at: 5.5) == .none && h.phase == .idle)
        _ = h.modifiers([], at: 5.6)
        _ = h.modifiers([62], at: 6)
        _ = h.tick(at: 6.2)
        check("hold: another modifier after start cancels", h.modifiers([62, 58], at: 6.3) == .cancel)
        _ = h.modifiers([], at: 7)
        _ = h.modifiers([58], at: 7.1)
        check("hold: pressing the key while another is down doesn't count", h.modifiers([58, 62], at: 7.2) == .none && h.tick(at: 7.5) == .none)

        // Through the event tap: talk on Right Control.
        let store = KeybindStore(memory: nil)
        store.set(rightCtrl, for: .talk)
        let tap = FakeTap(store: store)
        tap.modifier(62, down: true, at: 0)
        check("modifier talk: a timer is set when the key goes down", tap.timers.count == 1)
        tap.fire(at: 0.16)
        check("modifier talk: starts after 150 ms", tap.take() == ["talk"])
        tap.modifier(62, down: false, at: 1)
        check("modifier talk: letting go sends", tap.take() == ["end"])
        tap.modifier(62, down: true, at: 2)
        let copy = tap.key(8, down: true, at: 2.05) // Control+C, quickly
        _ = tap.key(8, down: false)
        tap.fire(at: 2.16)
        tap.modifier(62, down: false, at: 2.3)
        check("modifier talk: Control+C before 150 ms copies, no talk at all", !copy && tap.take().isEmpty)
        tap.modifier(62, down: true, at: 3)
        tap.fire(at: 3.16)
        let late = tap.key(8, down: true, at: 3.5) // Control+C, slowly
        _ = tap.key(8, down: false)
        tap.modifier(62, down: false, at: 3.6)
        check("modifier talk: a key after start cancels (recording thrown away) and the key goes through", !late && tap.take() == ["talk", "cancel"])
        tap.modifier(62, down: true, at: 4)
        tap.fire(at: 4.16)
        let click = tap.click()
        tap.modifier(62, down: false, at: 4.6)
        check("modifier talk: a click after start cancels, the click goes through", !click && tap.take() == ["talk", "cancel"])
        tap.modifier(62, down: true, at: 5)
        tap.modifier(62, down: false, at: 5.1)
        tap.fire(at: 5.16)
        check("modifier talk: a quick tap never talks", tap.take().isEmpty)
        tap.modifier(62, down: true, at: 6)
        tap.held = [] // its key-up was lost
        tap.fire(at: 6.16)
        check("modifier talk: a lost key-up never turns the microphone on", tap.take().isEmpty)
        tap.modifier(62, down: false, at: 6.5)
        tap.modifier(59, down: true, at: 7) // Left Control: not the talk key
        tap.fire(at: 7.2)
        tap.modifier(59, down: false, at: 7.3)
        check("modifier talk: the other Control key doesn't talk", tap.take().isEmpty)
        check("modifier talk: the key's own events are never swallowed",
              !tap.modifier(62, down: true, at: 8) && { tap.fire(at: 8.2); return !tap.modifier(62, down: false, at: 8.5) }() && tap.take() == ["talk", "end"])
        tap.modifier(56, down: true, at: 9); tap.modifier(56, down: false, at: 9.05)
        tap.modifier(56, down: true, at: 9.3); tap.modifier(56, down: false, at: 9.35)
        check("double Shift still works with talk on a modifier", tap.take() == ["double"])

        // The recorder's lone press.
        var r = LoneModifierPress()
        check("recorder: a modifier pressed and let go alone is caught", r.flags([62]) == nil && r.flags([]) == 62)
        check("recorder: two modifiers together aren't", r.flags([59]) == nil && r.flags([59, 56]) == nil && r.flags([56]) == nil && r.flags([]) == nil)
        _ = r.flags([55]); r.key()
        check("recorder: a modifier used with a key isn't", r.flags([]) == nil)
        check("recorder: left and right are told apart from the flags",
              ModifierKeys.down(ModifierKeys.flags([61]).rawValue) == [61] && ModifierKeys.down(ModifierKeys.flags([58, 54]).rawValue) == [58, 54]
              && ModifierKeys.down(CGEventFlags.maskSecondaryFn.rawValue) == [63])
    }

    /// Point to ask: hold Shift alone, move, let go.
    static func pointToAskChecks(_ check: (String, Bool) -> Void) {
        // The rule.
        var h = ModifierHold(keys: [56, 60], delay: 0.2, minMove: 40)
        _ = h.modifiers([56], at: 0, mouse: CGPoint(x: 100, y: 100))
        check("point: no start before 200 ms, even after a long move", h.tick(at: 0.1, mouse: CGPoint(x: 200, y: 100)) == .none)
        check("point: starts once 200 ms have passed and it moved 40 points", h.tick(at: 0.21, mouse: CGPoint(x: 190, y: 100)) == .start)
        check("point: letting go of Shift asks", h.modifiers([], at: 0.5) == .end)
        _ = h.modifiers([60], at: 1, mouse: .zero)
        check("point: no start under 40 points", h.tick(at: 1.5, mouse: CGPoint(x: 30, y: 20)) == .none && h.phase == .pending)
        check("point: the right Shift works too, once it moves far enough", h.tick(at: 1.6, mouse: CGPoint(x: 30, y: 30)) == .start)
        _ = h.modifiers([], at: 2)

        // Through the event tap.
        let tap = FakeTap()
        tap.mouse = CGPoint(x: 100, y: 100)
        tap.modifier(56, down: true, at: 0)
        tap.move(to: CGPoint(x: 150, y: 100), at: 0.1)
        check("point tap: nothing before 200 ms", tap.take().isEmpty)
        tap.move(to: CGPoint(x: 160, y: 100), at: 0.25)
        tap.move(to: CGPoint(x: 170, y: 110), at: 0.3)
        tap.modifier(56, down: false, at: 0.6)
        check("point tap: hold, move, let go → the trail is drawn and asked about", tap.take() == ["point", "move", "ask"])
        tap.gap()
        tap.modifier(56, down: true, at: 1)
        tap.move(to: CGPoint(x: 190, y: 120), at: 1.5) // 22 points from where Shift went down
        tap.modifier(56, down: false, at: 1.6)
        check("point tap: a small move does nothing", tap.take().isEmpty)
        tap.gap()
        tap.modifier(56, down: true, at: 2)
        let capital = tap.key(0, down: true, at: 2.1) // Shift+A: a capital
        _ = tap.key(0, down: false)
        tap.move(to: CGPoint(x: 300, y: 300), at: 2.5)
        tap.modifier(56, down: false, at: 2.6)
        check("point tap: typing a capital cancels and types", !capital && tap.take().isEmpty)
        tap.gap()
        tap.modifier(56, down: true, at: 3)
        tap.move(to: CGPoint(x: 400, y: 300), at: 3.3)
        let letter = tap.key(0, down: true, at: 3.4)
        _ = tap.key(0, down: false)
        tap.modifier(56, down: false, at: 3.5)
        check("point tap: a letter after start cancels at once and is typed", !letter && tap.take() == ["point", "point-cancel"])
        tap.gap()
        tap.modifier(56, down: true, at: 4)
        tap.move(to: CGPoint(x: 500, y: 300), at: 4.3)
        let shiftClick = tap.click()
        tap.modifier(56, down: false, at: 4.5)
        check("point tap: a Shift-click cancels and still clicks", !shiftClick && tap.take() == ["point", "point-cancel"])
        tap.gap()
        tap.modifier(56, down: true, at: 5)
        tap.click() // Shift-click before anything started
        tap.move(to: CGPoint(x: 700, y: 300), at: 5.4)
        tap.modifier(56, down: false, at: 5.5)
        check("point tap: a Shift-click before the start stays a plain Shift-click", tap.take().isEmpty)
        tap.gap()
        tap.modifier(56, down: true, at: 6)
        tap.move(to: CGPoint(x: 800, y: 300), at: 6.3)
        tap.click(.scrollWheel)
        tap.modifier(56, down: false, at: 6.5)
        check("point tap: a scroll cancels", tap.take() == ["point", "point-cancel"])
        tap.gap()
        tap.modifier(56, down: true, at: 7)
        tap.modifier(55, down: true, at: 7.05) // ⌘⇧…: a shortcut
        tap.move(to: CGPoint(x: 900, y: 300), at: 7.4)
        tap.modifier(55, down: false, at: 7.5)
        tap.modifier(56, down: false, at: 7.6)
        check("point tap: another modifier cancels", tap.take().isEmpty)
        tap.gap()
        tap.modifier(56, down: true, at: 8); tap.modifier(56, down: false, at: 8.05)
        tap.modifier(56, down: true, at: 8.3); tap.modifier(56, down: false, at: 8.35)
        check("point tap: double Shift still means a screenshot", tap.take() == ["double"])
        tap.pointOn = false
        tap.gap()
        tap.modifier(56, down: true, at: 8.5)
        let shiftTab = tap.key(48, down: true, at: 8.6) // Shift+Tab before anything started: moves focus back, as always
        _ = tap.key(48, down: false)
        tap.move(to: CGPoint(x: 100, y: 600), at: 8.9)
        tap.modifier(56, down: false, at: 9.0)
        check("point tap: Shift+Tab before the start cancels and goes through", !shiftTab && tap.take().isEmpty)
        tap.gap()
        tap.modifier(56, down: true, at: 9)
        tap.move(to: CGPoint(x: 100, y: 100), at: 9.5)
        tap.modifier(56, down: false, at: 9.6)
        check("point tap: turned off, nothing happens", tap.take().isEmpty)
        tap.pointOn = true
        tap.pointKeys = [60]
        tap.gap()
        tap.modifier(56, down: true, at: 10)
        tap.move(to: CGPoint(x: 300, y: 100), at: 10.5)
        tap.modifier(56, down: false, at: 10.6)
        check("point tap: set to Right Shift, Left Shift does nothing", tap.take().isEmpty)
        tap.pointKeys = [56, 60]

        // Talking while pointing: the picture goes with the words.
        tap.gap()
        tap.modifier(56, down: true, at: 11)
        tap.move(to: CGPoint(x: 100, y: 300), at: 11.3)
        let tabDown = tap.key(48, down: true, at: 11.4)
        _ = tap.key(12, down: true, at: 11.5)
        _ = tap.key(12, down: false, at: 12)
        _ = tap.key(48, down: false, at: 12.1)
        tap.modifier(56, down: false, at: 12.2)
        check("point tap: holding Tab + Q while pointing talks and keeps pointing", !tabDown && tap.take() == ["point", "talk", "end", "ask+talk"])
        let store = KeybindStore(memory: nil)
        store.set(.modifierOnly(62), for: .talk)
        let both = FakeTap(store: store)
        both.modifier(62, down: true, at: 0)
        both.fire(at: 0.16)
        both.modifier(56, down: true, at: 0.5)
        both.move(to: CGPoint(x: 700, y: 400), at: 0.8)
        both.modifier(56, down: false, at: 1.0)
        both.modifier(62, down: false, at: 1.2)
        check("point tap: talk on Right ⌃ and Shift pointing don't cancel each other", both.take() == ["talk", "point", "ask+talk", "end"])

        // Where the picture is taken.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        check("point box: the trail's box plus 24 points",
              PointGeometry.captureRect(trail: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 150), CGPoint(x: 150, y: 120)], screens: [screen])
              == CGRect(x: 76, y: 76, width: 148, height: 98))
        check("point box: kept inside the screen at its edges",
              PointGeometry.captureRect(trail: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 40)], screens: [screen]) == CGRect(x: 0, y: 0, width: 74, height: 64)
              && PointGeometry.captureRect(trail: [CGPoint(x: 1400, y: 880), CGPoint(x: 1430, y: 895)], screens: [screen]) == CGRect(x: 1376, y: 856, width: 64, height: 44))
        let second = CGRect(x: 1440, y: -180, width: 1920, height: 1080)
        check("point box: clamped to the screen the trail ended on",
              PointGeometry.captureRect(trail: [CGPoint(x: 1420, y: 100), CGPoint(x: 1500, y: 120)], screens: [screen, second])
              == CGRect(x: 1440, y: 76, width: 84, height: 68))
        check("point box: no trail, no picture", PointGeometry.captureRect(trail: [], screens: [screen]) == nil
              && PointGeometry.captureRect(trail: [CGPoint(x: 5000, y: 5000)], screens: [screen]) == nil)
        check("point box: top-left and AppKit points convert both ways",
              PointGeometry.toAppKit(CGPoint(x: 10, y: 20), mainHeight: 900) == CGPoint(x: 10, y: 880)
              && PointGeometry.topLeftFrame(CGRect(x: 1440, y: 0, width: 1920, height: 1080), mainHeight: 900) == second)
    }
}

extension FeatureTests {
    /// The capture waits for the trail window to be gone (never a fixed sleep, never longer than the limit), and a
    /// point-to-ask picture is labelled as one.
    static func trailGateChecks(_ check: (String, Bool) -> Void) {
        func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        var result: (waited: TimeInterval, timedOut: Bool)?
        WindowGate.wait(until: { true }) { result = ($0, $1) }
        check("trail gate: a window already gone starts the capture at once", result?.timedOut == false && (result?.waited ?? 1) < 0.005)

        var looks = 0
        result = nil
        WindowGate.wait(until: { looks += 1; return looks >= 4 }) { result = ($0, $1) }
        check("trail gate: it does not block while it waits", result == nil)
        spin(0.15)
        check("trail gate: it goes as soon as the window is gone (4th look), well inside the limit",
              result?.timedOut == false && looks == 4 && (result?.waited ?? 1) < 0.2)

        result = nil
        WindowGate.wait(until: { false }, limit: 0.06) { result = ($0, $1) }
        spin(0.25)
        check("trail gate: a window that never goes stops the wait at the limit, and says so",
              result?.timedOut == true && (result?.waited ?? 0) >= 0.06 && (result?.waited ?? 1) < 0.2)
        check("trail gate: the limit is 300 ms, looked at every 10 ms", WindowGate.limit == 0.3 && WindowGate.tick == 0.01)
        check("trail gate: a window number that doesn't exist is not on screen", !WindowGate.isOnScreen(999_999_999))

        func shot(_ source: ScreenshotRecord.Source) -> ScreenshotRecord {
            var s = ScreenshotRecord(title: "t", sector: "Math", app: "Safari", windowTitle: "", source: source, text: "", width: 10, height: 10, originalPath: nil)
            s.source = source
            return s
        }
        check("trail label: a point-to-ask picture says so; a snip and a screenshot keep their names",
              shot(.point).sourceLabel == "Point to ask" && shot(.snip).sourceLabel == "Snip (Tab+\\)" && shot(.system).sourceLabel == "Screenshot")
        if let data = try? JSONEncoder().encode(shot(.point)), var json = String(data: data, encoding: .utf8) {
            check("trail label: it survives saving", (try? JSONDecoder().decode(ScreenshotRecord.self, from: data))?.source == .point)
            json = json.replacingOccurrences(of: "\"source\":\"point\"", with: "\"source\":\"hologram\"")
            check("trail label: a kind this version doesn't know loads as a plain screenshot",
                  (try? JSONDecoder().decode(ScreenshotRecord.self, from: Data(json.utf8)))?.source == .system)
        }
    }
}
