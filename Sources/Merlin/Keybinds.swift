import AppKit
import IOKit.hidsystem
import Foundation
import SwiftUI

/// One key chord: a key, the modifiers held with it, and (for Merlin's snip) whether Tab is held down first.
struct Chord: Codable, Equatable {
    var keyCode: Int64
    var command = false
    var shift = false
    var option = false
    var control = false
    var holdTab = false
    /// A modifier key held on its own (the whole chord is that one key, left and right are different keys). Only hold
    /// commands like talk can use one. Absent in older saved data, which still loads.
    var modifierKey: Int64? = nil

    /// A chord that is one modifier key held on its own, like Right ⌃ or Fn.
    static func modifierOnly(_ code: Int64) -> Chord { Chord(keyCode: -1, modifierKey: code) }

    /// The modifier keys talk can be held on: Option, Control, Command (left and right) and Fn. Shift is kept for
    /// point to ask and the double-Shift screenshot; Caps Lock locks.
    static let holdableModifiers: Set<Int64> = [58, 61, 59, 62, 55, 54, 63]

    /// The name of a modifier key, left and right told apart.
    static func modifierName(_ code: Int64) -> String {
        switch code {
        case 58: return "Left ⌥"
        case 61: return "Right ⌥"
        case 59: return "Left ⌃"
        case 62: return "Right ⌃"
        case 55: return "Left ⌘"
        case 54: return "Right ⌘"
        case 56: return "Left ⇧"
        case 60: return "Right ⇧"
        case 63: return "Fn"
        case 57: return "Caps Lock"
        default: return "Key \(code)"
        }
    }

    /// Exact match on the four modifiers (caps lock, fn and the like don't count). A modifier-only chord never matches a keyDown.
    func matches(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool) -> Bool {
        modifierKey == nil
            && keyCode == self.keyCode
            && flags.contains(.maskCommand) == command && flags.contains(.maskShift) == shift
            && flags.contains(.maskAlternate) == option && flags.contains(.maskControl) == control
            && (!holdTab || tabHeld)
    }

    /// A chord has to be something you wouldn't type by accident: Tab held, or Command, Option or Control.
    var isUsable: Bool { holdTab || command || option || control }

    var display: String {
        if let modifierKey { return Self.modifierName(modifierKey) }
        return (holdTab ? "Tab + " : "") + (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "")
            + Self.keyName(keyCode)
    }

    /// The four Mac modifier keys (Shift, Control, Option, Command, left and right) and Caps Lock and fn: never a chord's main key.
    static let modifierKeyCodes: Set<Int64> = [54, 55, 56, 57, 58, 59, 60, 61, 62, 63]

    /// The same chord as a SwiftUI shortcut (US key layout), or nil for a key SwiftUI can't name (F-keys) or a hold-Tab chord.
    var keyboardShortcut: KeyboardShortcut? {
        guard !holdTab, modifierKey == nil, let key = Self.swiftUIKey(keyCode) else { return nil }
        var mods: EventModifiers = []
        if command { mods.insert(.command) }
        if shift { mods.insert(.shift) }
        if option { mods.insert(.option) }
        if control { mods.insert(.control) }
        return KeyboardShortcut(key, modifiers: mods)
    }

    private static func swiftUIKey(_ code: Int64) -> KeyEquivalent? {
        switch code {
        case 36: return .return
        case 48: return .tab
        case 49: return .space
        case 51: return .delete
        case 53: return .escape
        case 123: return .leftArrow
        case 124: return .rightArrow
        case 125: return .downArrow
        case 126: return .upArrow
        default:
            guard let name = names[code], name.count == 1, let c = name.lowercased().first else { return nil }
            return KeyEquivalent(c)
        }
    }

    /// How an `NSMenuItem` shows this chord: its key and modifiers, or nil when a menu can't (hold-Tab chords, F-keys).
    var menuEquivalent: (key: String, mask: NSEvent.ModifierFlags)? {
        guard !holdTab, modifierKey == nil else { return nil }
        let key: String
        switch keyCode {
        case 36: key = "\r"
        case 48: key = "\t"
        case 49: key = " "
        case 51: key = "\u{8}"
        case 53: key = "\u{1b}"
        case 123: key = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case 124: key = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case 125: key = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case 126: key = String(UnicodeScalar(NSUpArrowFunctionKey)!)
        default:
            guard let name = Self.names[keyCode], name.count == 1 else { return nil }
            key = name.lowercased()
        }
        var mask: NSEvent.ModifierFlags = []
        if command { mask.insert(.command) }
        if shift { mask.insert(.shift) }
        if option { mask.insert(.option) }
        if control { mask.insert(.control) }
        return (key, mask)
    }

    /// Plain words for menus and messages: "hold Tab, press \\" for the snip chord, the key symbols for the rest.
    var spoken: String { holdTab ? "hold Tab, press " + Chord(keyCode: keyCode, command: command, shift: shift, option: option, control: control).display : display }

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

// MARK: - Commands: the one list of everything that has a shortcut

/// Where a shortcut works. A global one is caught system-wide by the event tap, so it is swallowed in every app;
/// the others only work while that window is in front.
enum ShortcutScope: String, CaseIterable {
    case global, chat, library

    /// The heading in Settings → Shortcuts.
    var heading: String {
        switch self {
        case .global: return "Anywhere"
        case .chat: return "In a chat"
        case .library: return "In the Library"
        }
    }

    /// Can a command in this scope and one in `other` be live at the same moment? A global one is live everywhere,
    /// so it overlaps every scope; chat and Library are different windows, so they only overlap themselves.
    func overlaps(_ other: ShortcutScope) -> Bool { self == .global || other == .global || self == other }
}

/// One thing a shortcut can do. `id` is what's stored, so it never changes once shipped.
struct ShortcutCommand: Equatable, Identifiable {
    let id: String
    let scope: ShortcutScope
    let title: String
    let detail: String
    let defaultChord: Chord

    // Anywhere (caught by the event tap in Hotkeys). The ids are the ones the first version stored.
    static let snip = ShortcutCommand(id: "snip", scope: .global, title: "Snip the screen",
        detail: "Hold the first key, then press the second, and drag over what you want to ask about.", defaultChord: Chord(keyCode: 42, holdTab: true))
    static let chat = ShortcutCommand(id: "chat", scope: .global, title: "Open a chat",
        detail: "Open (or put away) a chat at your mouse.", defaultChord: Chord(keyCode: 48, shift: true, option: true))
    static let talk = ShortcutCommand(id: "talk", scope: .global, title: "Talk to Merlin",
        detail: "Hold to talk, let go to send.", defaultChord: Chord(keyCode: 12, holdTab: true))
    static let history = ShortcutCommand(id: "history", scope: .global, title: "Library",
        detail: "Open or close the Library.", defaultChord: Chord(keyCode: 37, command: true, shift: true))
    static let engine = ShortcutCommand(id: "engine", scope: .global, title: "Switch model",
        detail: "Move the open chat between Claude and the model on this Mac.", defaultChord: Chord(keyCode: 37, shift: true, control: true))

    // In the Library window.
    static let libraryNewChat = ShortcutCommand(id: "library.newChat", scope: .library, title: "New chat",
        detail: "Start a new chat from the Library.", defaultChord: Chord(keyCode: 45, command: true))
    static let librarySearch = ShortcutCommand(id: "library.search", scope: .library, title: "Search",
        detail: "Jump to the search box.", defaultChord: Chord(keyCode: 40, command: true))
    static let librarySearchAlt = ShortcutCommand(id: "library.searchAlt", scope: .library, title: "Search (second shortcut)",
        detail: "A second way to jump to the search box.", defaultChord: Chord(keyCode: 3, command: true))
    static let libraryMove = ShortcutCommand(id: "library.move", scope: .library, title: "Move to a sector",
        detail: "File the chats you picked under a sector.", defaultChord: Chord(keyCode: 46, command: true, shift: true))
    static let libraryBin = ShortcutCommand(id: "library.bin", scope: .library, title: "Move to the Bin",
        detail: "Put the chats, notes or screenshots you picked in the Bin.", defaultChord: Chord(keyCode: 51, command: true))

    // The settings page lives in the Library window. Each is only live on its own page, but for clashes they count as the
    // same scope as the other Library commands (simple, and never wrong in the safe direction).
    static let libraryOpenSettings = ShortcutCommand(id: "library.openSettings", scope: .library, title: "Open settings",
        detail: "Open Merlin's settings from the Library.", defaultChord: Chord(keyCode: 43, command: true))
    static let libraryBack = ShortcutCommand(id: "library.back", scope: .library, title: "Back to the Library",
        detail: "Leave the settings and go back to the Library.", defaultChord: Chord(keyCode: 33, command: true))

    /// Every command, in the order they're listed and in the order they win a clash (globals first).
    /// There are no chat-window commands yet: the chat's only keys are Esc and Return, which stay fixed.
    static let all: [ShortcutCommand] = [snip, chat, talk, history, engine,
                                         libraryNewChat, librarySearch, librarySearchAlt, libraryMove, libraryBin,
                                         libraryOpenSettings, libraryBack]

    static func named(_ id: String) -> ShortcutCommand? { all.first { $0.id == id } }

    /// Only a hold command can be one modifier key on its own (held, then let go). Today that is talk.
    var allowsModifierOnly: Bool { id == Self.talk.id }
    static func inScope(_ scope: ShortcutScope) -> [ShortcutCommand] { all.filter { $0.scope == scope } }
}

/// Every chord Merlin listens for, and the double-Shift screenshot.
///
/// The saved shape is `{"chords": {"<command id>": {...}}, "doubleShift": true}`, as it always was: a command that isn't
/// in the saved data (one added later) takes its default, and saved ids that no longer exist are dropped.
struct Keybinds: Codable, Equatable {
    var chords: [String: Chord]
    /// Tap Shift twice, quickly, to add a screenshot of your screen to the open chat.
    var doubleShift = true
    /// Set once talk has moved from its first default (⌘⇧V) to Tab + Q. Missing in older saved data (read as nil), which
    /// is how the one-time move knows it hasn't happened yet. After that a ⌘⇧V you pick yourself is kept.
    var talkMoved: Bool? = true

    /// Talk's first default, before it moved to Tab + Q.
    static let oldTalkDefault = Chord(keyCode: 9, command: true, shift: true)

    static let defaults = Keybinds(chords: Dictionary(uniqueKeysWithValues: ShortcutCommand.all.map { ($0.id, $0.defaultChord) }))

    func chord(_ id: String) -> Chord { chords[id] ?? ShortcutCommand.named(id)?.defaultChord ?? Chord(keyCode: -1) }
    func chord(_ command: ShortcutCommand) -> Chord { chord(command.id) }

    /// The global command a keyDown completes. Only global commands are caught here; if two share a chord the first in list order wins.
    func action(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool) -> Hotkeys.Action? {
        Hotkeys.Action.allCases.first { chord($0.command).matches(keyCode: keyCode, flags: flags, tabHeld: tabHeld) }
    }

    var isDefault: Bool { self == Self.defaults }

    // MARK: Conflicts

    /// THE conflict rule: two commands clash when they're on the same chord and can be live at the same moment.
    /// A global chord is swallowed system-wide, so it clashes with everything; a chat chord and a Library chord on the
    /// same keys don't clash (different windows).
    static func clash(_ a: Chord, in sa: ShortcutScope, _ b: Chord, in sb: ShortcutScope) -> Bool {
        a == b && sa.overlaps(sb)
    }

    /// The other commands that clash with `command` (as it's set now, or with `chord` instead), in list order.
    func rivals(of command: ShortcutCommand, using chord: Chord? = nil) -> [ShortcutCommand] {
        let mine = chord ?? self.chord(command)
        return ShortcutCommand.all.filter { $0.id != command.id && Self.clash(mine, in: command.scope, self.chord($0), in: $0.scope) }
    }

    /// Chords Mac or Merlin already use for something fixed (not listed in Settings). The text finishes "Used by …".
    private static let fixed: [(Chord, String)] = {
        func cmd(_ code: Int64, shift: Bool = false) -> Chord { Chord(keyCode: code, command: true, shift: shift) }
        return [
            (cmd(8), "macOS for Copy"), (cmd(9), "macOS for Paste"), (cmd(7), "macOS for Cut"), (cmd(6), "macOS for Undo"),
            (cmd(6, shift: true), "macOS for Redo"), (cmd(0), "macOS for Select All"),
            (cmd(12), "macOS for Quit"), (cmd(13), "macOS for Close Window"), (cmd(4), "macOS for Hide"), (cmd(46), "macOS for Minimise"),
            (cmd(49), "macOS for Spotlight"), (cmd(48), "macOS for switching apps"),
            (cmd(50), "macOS for switching windows"),
            (cmd(20, shift: true), "macOS for Screenshots"), (cmd(21, shift: true), "macOS for Screenshots"),
            (cmd(23, shift: true), "macOS for Screenshots"),
            (Chord(keyCode: 53), "Merlin for closing or cancelling"), (Chord(keyCode: 36), "Merlin for Send"),
            (Chord(keyCode: 126), "Merlin for moving through lists"), (Chord(keyCode: 125), "Merlin for moving through lists"),
            (Chord(keyCode: 51), "Merlin for Move to the Bin"),
        ]
    }()

    /// What a fixed shortcut already does with this chord, as "macOS for Copy", or nil. Never counts a chord a command has by default.
    static func fixedUse(of chord: Chord) -> String? {
        guard !ShortcutCommand.all.contains(where: { $0.defaultChord == chord }) else { return nil }
        return fixed.first { $0.0 == chord }?.1
    }

    /// What `command` collides with, in words: "Also used by Search", "Used by macOS for Copy". Empty when it's clear.
    struct Clash: Equatable {
        var rivals: [ShortcutCommand]
        var fixedUse: String?
        var isEmpty: Bool { rivals.isEmpty && fixedUse == nil }
    }

    func clash(of command: ShortcutCommand) -> Clash {
        Clash(rivals: rivals(of: command), fixedUse: Self.fixedUse(of: chord(command)))
    }

    /// Commands in a clash of either kind, in list order.
    var conflicting: [ShortcutCommand] { ShortcutCommand.all.filter { !clash(of: $0).isEmpty } }

    /// The chord a command actually fires on. While two commands clash, the first in list order fires and the other is
    /// dead until it's changed: globals come first, which matches reality (the event tap swallows the keys before any window).
    func effectiveChord(for command: ShortcutCommand) -> Chord? {
        let mine = chord(command)
        for other in ShortcutCommand.all {
            if other.id == command.id { return mine }
            if Self.clash(mine, in: command.scope, chord(other), in: other.scope) { return nil }
        }
        return mine
    }

    // MARK: Unusable chords

    /// Why `chord` can never work for `command` (so it's refused), or nil. A clash isn't one: that's saved and shown in red.
    static func problem(_ chord: Chord, for command: ShortcutCommand) -> String? {
        if let key = chord.modifierKey {
            guard command.allowsModifierOnly else { return "A modifier key can't be a shortcut on its own. Press it together with another key." }
            if key == 56 || key == 60 { return "Shift on its own is kept for point to ask and the double-Shift screenshot. Pick another key." }
            guard Chord.holdableModifiers.contains(key) else { return "\(Chord.modifierName(key)) can't be held on its own. Use Option, Control, Command or Fn." }
            return nil
        }
        if Chord.modifierKeyCodes.contains(chord.keyCode) { return "A modifier key can't be a shortcut on its own. Press it together with another key." }
        if command.scope != .global && chord.holdTab { return "Holding Tab only works for shortcuts that work anywhere." }
        if command.scope == .global {
            if !chord.isUsable { return "Use Command, Option or Control (or hold Tab), so typing never triggers it." }
        } else {
            if !(chord.command || chord.option || chord.control) { return "Use Command, Option or Control, so typing never triggers it." }
            if chord.keyboardShortcut == nil { return "\(chord.display) can't be used inside a window. Pick another key." }
        }
        return nil
    }
}

/// Where the chords live: UserDefaults as JSON (or nowhere, for tests and screenshots). Read from the key-tap thread, so reads are locked.
final class KeybindStore {
    static let changed = Notification.Name("merlin.keybinds.changed")
    /// The unit tests and the settings screenshots get their own throwaway store, so your saved shortcuts are never read or changed.
    static let shared: KeybindStore = {
        let args = CommandLine.arguments
        return args.contains("--unittest") || args.contains("--settingsshots") ? KeybindStore(memory: nil) : KeybindStore(defaults: .standard)
    }()

    private let defaults: UserDefaults?
    private let lock = NSLock()
    private var value: Keybinds
    /// The JSON as last written (what a second store would read back).
    private(set) var saved: Data?
    private static let key = "keybinds"

    /// A store backed by UserDefaults.
    convenience init(defaults: UserDefaults) {
        self.init(defaults: defaults, seed: defaults.data(forKey: Self.key))
    }

    /// A store that never touches disk. `seed` is JSON to start from, as if it had been saved.
    convenience init(memory seed: Data?) {
        self.init(defaults: nil, seed: seed)
    }

    private init(defaults: UserDefaults?, seed: Data?) {
        self.defaults = defaults
        saved = seed
        value = Self.read(seed)
    }

    /// Saved JSON → chords. Anything missing (a command added later) takes its default; unknown ids and unreadable data are ignored.
    static func read(_ data: Data?) -> Keybinds {
        guard let data, let saved = try? JSONDecoder().decode(Keybinds.self, from: data) else { return .defaults }
        var merged = Keybinds.defaults
        for (k, v) in saved.chords where Keybinds.defaults.chords[k] != nil { merged.chords[k] = v }
        merged.doubleShift = saved.doubleShift
        // Once only: talk on the old default (or not saved at all) moves to the new default. Any other choice is kept.
        if saved.talkMoved != true {
            let talk = saved.chords[ShortcutCommand.talk.id]
            if talk == nil || talk == Keybinds.oldTalkDefault { merged.chords[ShortcutCommand.talk.id] = ShortcutCommand.talk.defaultChord }
        }
        merged.talkMoved = true
        return merged
    }

    var current: Keybinds { lock.lock(); defer { lock.unlock() }; return value }

    func update(_ change: (inout Keybinds) -> Void) {
        lock.lock()
        var next = value
        change(&next)
        value = next
        lock.unlock()
        if let data = try? JSONEncoder().encode(next) {
            saved = data
            defaults?.set(data, forKey: Self.key)
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Sets one chord. Returns why it was refused (and changes nothing) when the chord can never work, or nil when it's saved.
    /// A chord another command already uses IS saved: both commands then show as clashing (see `Keybinds.clash`).
    @discardableResult
    func set(_ chord: Chord, for command: ShortcutCommand) -> String? {
        if let why = Keybinds.problem(chord, for: command) { return why }
        update { $0.chords[command.id] = chord }
        return nil
    }

    func reset(_ command: ShortcutCommand) { update { $0.chords[command.id] = command.defaultChord } }
    func resetAll() { update { $0 = .defaults } }
}

// MARK: - Putting the chosen chord on a SwiftUI button

/// `.keyboardShortcut` that follows Settings → Shortcuts and updates the moment it changes. Attaches nothing while the
/// command loses a clash (see `Keybinds.effectiveChord`) or its key can't be a SwiftUI shortcut.
private struct MerlinShortcut: ViewModifier {
    let command: ShortcutCommand
    let help: String?
    @State private var shortcut: KeyboardShortcut?
    @State private var hint = ""

    init(_ command: ShortcutCommand, help: String?) {
        self.command = command
        self.help = help
        _hint = State(initialValue: command.hint)
        _shortcut = State(initialValue: Self.current(command))
    }

    private static func current(_ command: ShortcutCommand) -> KeyboardShortcut? {
        KeybindStore.shared.current.effectiveChord(for: command)?.keyboardShortcut
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if let help { content.keyboardShortcut(shortcut).help("\(help) (\(hint))") } else { content.keyboardShortcut(shortcut) }
        }
        .onReceive(NotificationCenter.default.publisher(for: KeybindStore.changed)) { _ in
            shortcut = Self.current(command)
            hint = command.hint
        }
    }
}

extension View {
    /// `help` (optional) becomes the tooltip with the current chord in brackets: "New chat (⌘N)".
    func merlinShortcut(_ command: ShortcutCommand, help: String? = nil) -> some View { modifier(MerlinShortcut(command, help: help)) }
}

extension ShortcutCommand {
    /// The chord as set now, for a tooltip or a hint.
    var hint: String { KeybindStore.shared.current.chord(self).display }
}

/// The small key hint (like the one in the search box), following the current chord.
struct ShortcutKbd: View {
    let command: ShortcutCommand
    @State private var text: String
    init(_ command: ShortcutCommand) { self.command = command; _text = State(initialValue: command.hint) }
    var body: some View {
        Kbd(text).onReceive(NotificationCenter.default.publisher(for: KeybindStore.changed)) { _ in text = command.hint }
    }
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

/// Which modifier keys are down, left and right told apart, read from an event's flags (the device bits macOS adds).
enum ModifierKeys {
    private static let bits: [(UInt64, Int64)] = [
        (UInt64(NX_DEVICELCTLKEYMASK), 59), (UInt64(NX_DEVICERCTLKEYMASK), 62),
        (UInt64(NX_DEVICELSHIFTKEYMASK), 56), (UInt64(NX_DEVICERSHIFTKEYMASK), 60),
        (UInt64(NX_DEVICELCMDKEYMASK), 55), (UInt64(NX_DEVICERCMDKEYMASK), 54),
        (UInt64(NX_DEVICELALTKEYMASK), 58), (UInt64(NX_DEVICERALTKEYMASK), 61),
        (CGEventFlags.maskSecondaryFn.rawValue, 63),
    ]

    /// The key codes of every modifier key held in `raw` (CGEventFlags or NSEvent.ModifierFlags raw value).
    static func down(_ raw: UInt64) -> Set<Int64> { Set(bits.filter { raw & $0.0 != 0 }.map(\.1)) }

    /// The flags macOS would send with these keys held (for the tests' made-up events).
    static func flags(_ keys: Set<Int64>) -> CGEventFlags {
        var raw: UInt64 = 0
        for (bit, code) in bits where keys.contains(code) { raw |= bit }
        if keys.contains(59) || keys.contains(62) { raw |= CGEventFlags.maskControl.rawValue }
        if keys.contains(56) || keys.contains(60) { raw |= CGEventFlags.maskShift.rawValue }
        if keys.contains(55) || keys.contains(54) { raw |= CGEventFlags.maskCommand.rawValue }
        if keys.contains(58) || keys.contains(61) { raw |= CGEventFlags.maskAlternate.rawValue }
        return CGEventFlags(rawValue: raw)
    }
}

/// One modifier key held on its own: the rule for talk on a lone modifier (150 ms) and for point to ask (Shift, 200 ms
/// and 40 points of movement). It only decides; the caller passes the time and the pointer, so tests need no real time.
///
/// - The key goes down with nothing else held: a hold is pending.
/// - It starts once the key has been down `delay` seconds AND the pointer has travelled `minMove` points (checked on `tick`).
/// - Before that, another modifier, a key or a click drops it silently (Control+C, a capital, Shift-click stay normal).
/// - Once started: letting go ends it (send); another modifier, a key or a click cancels it.
/// - After a drop or cancel nothing restarts until the key is let go and pressed again.
struct ModifierHold {
    enum Output: Equatable { case none, start, end, cancel }
    enum Phase: Equatable { case idle, pending, active }

    /// The keys that count (one is enough: "either Shift" is both).
    var keys: Set<Int64>
    let delay: TimeInterval
    let minMove: CGFloat
    private(set) var phase: Phase = .idle
    private var downAt: TimeInterval = 0
    private var origin: CGPoint = .zero
    private var travelled: CGFloat = 0
    private var mineDown: Set<Int64> = []

    init(keys: Set<Int64>, delay: TimeInterval, minMove: CGFloat = 0) {
        self.keys = keys
        self.delay = delay
        self.minMove = minMove
    }

    var isBusy: Bool { phase != .idle }
    var isActive: Bool { phase == .active }
    /// Where the pointer was when the key went down.
    var startPoint: CGPoint { origin }

    /// The modifiers changed. `down` is every modifier key held now; keys in `ignoring` (the other hold's key) don't count.
    mutating func modifiers(_ down: Set<Int64>, ignoring: Set<Int64> = [], at time: TimeInterval, mouse: CGPoint = .zero) -> Output {
        let mine = down.intersection(keys)
        let others = down.subtracting(keys).subtracting(ignoring)
        let was = mineDown
        mineDown = mine
        switch phase {
        case .idle:
            if was.isEmpty, mine.count == 1, others.isEmpty {
                phase = .pending
                downAt = time
                origin = mouse
                travelled = 0
            }
            return .none
        case .pending:
            if mine.count == 1, mine == was, others.isEmpty { return .none }
            phase = .idle
            return .none
        case .active:
            if mine.isEmpty { phase = .idle; return .end }
            if !others.isEmpty || mine != was { phase = .idle; return .cancel }
            return .none
        }
    }

    /// Time passed or the pointer moved (nil: it didn't). Returns `.start` the moment both thresholds are met.
    mutating func tick(at time: TimeInterval, mouse: CGPoint? = nil) -> Output {
        guard phase == .pending else { return .none }
        if let mouse { travelled = max(travelled, hypot(mouse.x - origin.x, mouse.y - origin.y)) }
        guard time - downAt >= delay, time >= downAt, travelled >= minMove else { return .none }
        phase = .active
        return .start
    }

    /// A key was typed, a button clicked, or the wheel scrolled.
    mutating func interrupt() -> Output {
        defer { phase = .idle }
        return phase == .active ? .cancel : .none
    }

    /// Forget everything (the event tap was turned off and on, so a key-up may have been missed).
    mutating func reset() {
        phase = .idle
        mineDown = []
    }
}

/// The Shortcuts recorder's rule for a lone modifier: one modifier key pressed and let go with nothing else in between.
struct LoneModifierPress {
    private var candidate: Int64?
    private var previous: Set<Int64> = []

    /// The modifiers changed. Returns the key the moment a lone press is let go.
    mutating func flags(_ down: Set<Int64>) -> Int64? {
        defer { previous = down }
        if previous.isEmpty, down.count == 1 { candidate = down.first; return nil }
        if down.isEmpty, let key = candidate { candidate = nil; return key }
        if down.count > 1 { candidate = nil }
        return nil
    }

    /// A normal key was pressed: the modifier was part of a chord.
    mutating func key() { candidate = nil }
}

extension Hotkeys.Action {
    var command: ShortcutCommand { ShortcutCommand.named(rawValue)! }
    var title: String { command.title }
    var detail: String { command.detail }
}
