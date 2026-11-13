import AppKit

/// Margin's global key chords, caught with one event tap on its own thread:
/// - Tab+\ (hold Tab, press \): snip an area of the screen.
/// - Option+Shift+Tab: open (or put away) a chat at the mouse.
/// - Hold Cmd+Shift+V: talk to Margin (release to send). It replaces "paste and match style" while Margin runs.
/// - Cmd+Shift+L: open (or put away) the chat history.
/// - Control+Shift+L: move the open chat (just that one) between Claude and the model on this Mac.
/// - Cmd+Shift+3/4/5 (macOS's screenshots) are never touched: Margin just notes which app and window you were in, so the
///   screenshot that follows can be labeled by it.
/// Normal typing is never delayed: only the chord's final key is swallowed, so it never types into your document.
final class Hotkeys {
    var onSnip: (() -> Void)?
    var onChat: (() -> Void)?
    var onTalkStart: (() -> Void)?
    var onTalkEnd: (() -> Void)?
    var onHistory: (() -> Void)?
    var onEngine: (() -> Void)?
    /// Settings → Shortcuts is recording a new chord: every key is left alone so the window can see it.
    nonisolated(unsafe) static var paused = false
    /// ⌘⇧3, ⌘⇧4 or ⌘⇧5 was pressed. It's macOS's own shortcut, so it's passed on untouched; Margin only notes which window you're in.
    var onSystemShot: (() -> Void)?

    /// Tap Shift twice: add a screenshot of the screen to the open chat.
    var onDoubleShift: (() -> Void)?

    enum Action: String, CaseIterable, Equatable { case snip, chat, talk, history, engine }

    private static let tabKey: Int64 = 48            // kVK_Tab
    /// The talk key is down (touched only on the tap thread).
    private var talking = false
    /// Two quick Shift taps (touched only on the tap thread).
    private var doubleShift = DoubleShift()

    fileprivate var tap: CFMachPort?
    private var thread: Thread?
    /// The key whose keyDown we swallowed, so its keyUp is swallowed too.
    private var swallowedKey: Int64?

    /// Which chord (if any) a keyDown completes. `tabHeld` is whether Tab is physically down. `binds` are the chords in
    /// use (the defaults unless you've changed them in Settings → Shortcuts).
    static func action(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool, binds: Keybinds = .defaults) -> Action? {
        binds.action(keyCode: keyCode, flags: flags, tabHeld: tabHeld)
    }

    private static let screenshotKeys: Set<Int64> = [20, 21, 23] // kVK_ANSI_3, _4, _5

    /// macOS's screenshot chords that save a file: ⌘⇧3, ⌘⇧4, ⌘⇧5 (with Control they copy to the clipboard instead; no file).
    static func isSystemScreenshotChord(keyCode: Int64, flags: CGEventFlags) -> Bool {
        screenshotKeys.contains(keyCode) && flags.contains(.maskCommand) && flags.contains(.maskShift)
            && !flags.contains(.maskControl) && !flags.contains(.maskAlternate)
    }

    /// Needs Accessibility permission; returns false without it.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDown.rawValue) | CGEventMask(1 << CGEventType.rightMouseDown.rawValue)
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: hotkeysCallback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()),
              let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else { return false }
        self.tap = tap

        // Its own thread, so a busy main thread can never lag the user's keystrokes.
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "margin.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    /// Runs on the tap thread (and in the unit tests, with made-up key events).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if Self.paused { return pass }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let binds = KeybindStore.shared.current
        let talkKey = binds.chord(.talk).keyCode
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .flagsChanged:
            // Shift on its own, twice, quickly. Nothing is swallowed: Shift still does what it always does.
            let f = event.flags
            let others = f.contains(.maskCommand) || f.contains(.maskAlternate) || f.contains(.maskControl)
            if doubleShift.flagsChanged(shift: f.contains(.maskShift), others: others, at: ProcessInfo.processInfo.systemUptime),
               binds.doubleShift {
                DispatchQueue.main.async { [weak self] in self?.onDoubleShift?() }
            }
            return pass

        case .leftMouseDown, .rightMouseDown:
            doubleShift.interrupt() // a click means that Shift was for selecting
            return pass

        case .keyDown:
            doubleShift.interrupt() // a typed key means that Shift was for a capital or a chord
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // While talking, the key's auto-repeats are swallowed even if Cmd or Shift were let go first. A fresh press
            // (not a repeat) can't happen while the key is still down, so it means a key-up was missed: let go, carry on.
            if talking && keyCode == talkKey {
                if isRepeat { return nil }
                talking = false
                DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
            }
            if !isRepeat, Self.isSystemScreenshotChord(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onSystemShot?() }
                return pass // macOS takes the screenshot; Margin only notes where you were
            }
            let tabHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(Self.tabKey))
            guard let action = Self.action(keyCode: keyCode, flags: event.flags, tabHeld: tabHeld, binds: binds) else { return pass }
            if isRepeat { return nil }
            switch action {
            case .talk:
                talking = true
                DispatchQueue.main.async { [weak self] in self?.onTalkStart?() }
            case .snip, .chat, .history, .engine:
                swallowedKey = keyCode
                DispatchQueue.main.async { [weak self] in
                    switch action {
                    case .snip: self?.onSnip?()
                    case .history: self?.onHistory?()
                    case .engine: self?.onEngine?()
                    default: self?.onChat?()
                    }
                }
            }
            return nil

        case .keyUp:
            if keyCode == talkKey && talking {
                talking = false
                DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
                return nil
            }
            guard keyCode == swallowedKey else { return pass }
            swallowedKey = nil
            return nil

        default:
            return pass
        }
    }
}

private func hotkeysCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
