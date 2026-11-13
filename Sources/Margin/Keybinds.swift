import AppKit
import Foundation

/// One key chord: a key, the modifiers held with it, and (for Margin's snip) whether Tab is held down first.
struct Chord: Codable, Equatable {
    var keyCode: Int64
    var command = false
    var shift = false
    var option = false
    var control = false
    var holdTab = false

    /// Exact match on the four modifiers (caps lock, fn and the like don't count).
    func matches(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool) -> Bool {
        keyCode == self.keyCode
            && flags.contains(.maskCommand) == command && flags.contains(.maskShift) == shift
            && flags.contains(.maskAlternate) == option && flags.contains(.maskControl) == control
            && (!holdTab || tabHeld)
    }

    /// A chord has to be something you wouldn't type by accident: Tab held, or Command, Option or Control.
    var isUsable: Bool { holdTab || command || option || control }

    var display: String {
        (holdTab ? "Tab + " : "") + (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + Self.keyName(keyCode)
    }

    /// Why this chord is a poor choice (macOS or the app in front already uses it), or nil.
    var warning: String? {
        let cmdOnly = command && !shift && !option && !control && !holdTab
        if cmdOnly, [12, 13, 4, 46, 8, 9, 7, 0, 6, 1, 3, 48, 49].contains(keyCode) {
            return "\(display) is a standard Mac shortcut (quit, copy, paste…). Pick another."
        }
        if command && shift && !option && !control && [20, 21, 23].contains(keyCode) {
            return "\(display) takes macOS screenshots. Pick another."
        }
        return nil
    }

    /// "option+cmd+j", "⌘⇧H", "tab+\\" → a chord, or nil when it doesn't name a key.
    static func parse(_ text: String) -> Chord? {
        var chord = Chord(keyCode: -1)
        var rest = text.lowercased().replacingOccurrences(of: " ", with: "")
        for (symbol, word) in [("⌘", "cmd"), ("⌥", "opt"), ("⌃", "ctrl"), ("⇧", "shift")] { rest = rest.replacingOccurrences(of: symbol, with: word + "+") }
        let parts = rest.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        guard let key = parts.last else { return nil }
        for part in parts.dropLast() {
            switch part {
            case "cmd", "command": chord.command = true
            case "shift": chord.shift = true
            case "opt", "option", "alt": chord.option = true
            case "ctrl", "control": chord.control = true
            case "tab": chord.holdTab = true // Tab as a modifier: held first, then the last key
            default: return nil
            }
        }
        guard let code = names.first(where: { $0.value.lowercased() == key })?.key else { return nil }
        chord.keyCode = code
        return chord
    }

    private static let names: [Int64: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
            15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
            28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩", 37: "L", 38: "J", 39: "'", 40: "K",
            41: ";", 42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 48: "Tab", 49: "Space", 50: "`", 51: "⌫", 53: "Esc",
            96: "F5", 97: "F6", 98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 109: "F10", 111: "F12", 118: "F4",
            120: "F2", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]

    static func keyName(_ code: Int64) -> String {
        names[code] ?? "Key \(code)"
    }
}

/// Every chord Margin listens for, and the double-Shift screenshot.
struct Keybinds: Codable, Equatable {
    var chords: [String: Chord]
    /// Tap Shift twice, quickly, to add a screenshot of your screen to the open chat.
    var doubleShift = true

    static let defaults = Keybinds(chords: [
        Hotkeys.Action.snip.rawValue: Chord(keyCode: 42, holdTab: true),
        Hotkeys.Action.chat.rawValue: Chord(keyCode: 48, shift: true, option: true),
        Hotkeys.Action.talk.rawValue: Chord(keyCode: 9, command: true, shift: true),
        Hotkeys.Action.history.rawValue: Chord(keyCode: 37, command: true, shift: true),
        Hotkeys.Action.engine.rawValue: Chord(keyCode: 37, shift: true, control: true),
    ])

    func chord(_ action: Hotkeys.Action) -> Chord { chords[action.rawValue] ?? Self.defaults.chords[action.rawValue]! }

    func action(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool) -> Hotkeys.Action? {
        Hotkeys.Action.allCases.first { chord($0).matches(keyCode: keyCode, flags: flags, tabHeld: tabHeld) }
    }

    /// Another action already on this chord.
    func conflict(of action: Hotkeys.Action, with chord: Chord) -> Hotkeys.Action? {
        Hotkeys.Action.allCases.first { $0 != action && self.chord($0) == chord }
    }

    var isDefault: Bool { self == Self.defaults }
}

/// Where the chords live: UserDefaults as JSON. Read from the key-tap thread, so reads are locked.
final class KeybindStore {
    static let changed = Notification.Name("margin.keybinds.changed")
    /// The unit tests get their own empty store so a chord you changed never fails them.
    static let shared = KeybindStore(defaults: CommandLine.arguments.contains("--unittest")
        ? UserDefaults(suiteName: "margin.keybinds.unittest.\(UUID().uuidString)")! : .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: Keybinds
    private static let key = "keybinds"

    init(defaults: UserDefaults) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.key), let saved = try? JSONDecoder().decode(Keybinds.self, from: data) {
            // A chord added in a later version falls back to its default.
            var merged = Keybinds.defaults
            for (k, v) in saved.chords where Keybinds.defaults.chords[k] != nil { merged.chords[k] = v }
            merged.doubleShift = saved.doubleShift
            value = merged
        } else {
            value = .defaults
        }
    }

    var current: Keybinds { lock.lock(); defer { lock.unlock() }; return value }

    func update(_ change: (inout Keybinds) -> Void) {
        lock.lock()
        var next = value
        change(&next)
        value = next
        lock.unlock()
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: Self.key) }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Sets one chord. Returns why it was refused (and changes nothing), or nil when it's set.
    @discardableResult
    func set(_ chord: Chord, for action: Hotkeys.Action) -> String? {
        guard chord.isUsable else { return "Use Command, Option or Control (or hold Tab), so typing never triggers it." }
        if let warning = chord.warning { return warning }
        if let other = current.conflict(of: action, with: chord) { return "\(chord.display) is already used for \(other.title)." }
        update { $0.chords[action.rawValue] = chord }
        return nil
    }

    func reset(_ action: Hotkeys.Action) { update { $0.chords[action.rawValue] = Keybinds.defaults.chords[action.rawValue] } }
    func resetAll() { update { $0 = .defaults } }
}

/// "Tap Shift twice": two presses of Shift on its own, less than a second apart, with nothing typed or clicked in between.
struct DoubleShift {
    static let window: TimeInterval = 1.0
    private var shiftDown = false
    private var lastPress: TimeInterval?

    /// A modifier changed. Returns true when this was the second tap.
    mutating func flagsChanged(shift: Bool, others: Bool, at time: TimeInterval) -> Bool {
        defer { shiftDown = shift }
        if others { lastPress = nil; return false }
        guard shift, !shiftDown else { return false } // only the moment Shift goes down counts
        if let last = lastPress, time - last < Self.window, time >= last {
            lastPress = nil
            return true
        }
        lastPress = time
        return false
    }

    /// A key was typed or a button clicked: that Shift was for something else.
    mutating func interrupt() { lastPress = nil }
}

extension Hotkeys.Action {
    var title: String {
        switch self {
        case .snip: return "Snip the screen"
        case .chat: return "Open a chat"
        case .talk: return "Talk to Margin"
        case .history: return "Library"
        case .engine: return "Switch model"
        }
    }

    var detail: String {
        switch self {
        case .snip: return "Hold the first key, then press the second, and drag over what you want to ask about."
        case .chat: return "Open (or put away) a chat at your mouse."
        case .talk: return "Hold to talk, let go to send."
        case .history: return "Open or close the Library."
        case .engine: return "Move the open chat between Claude and the model on this Mac."
        }
    }
}
