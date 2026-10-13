import AppKit

/// Margin's global key chords, caught with one event tap on its own thread:
/// - Tab+\ (hold Tab, press \): snip an area of the screen.
/// - Option+Shift+Tab: open (or put away) a chat at the mouse.
/// - Hold Cmd+Shift+V: talk to Margin (release to send). It replaces "paste and match style" while Margin runs.
/// - Hold Cmd+Shift+V and press A (or hold Cmd+Shift+A and press V): talk to the agents: what you say is a job.
/// - Cmd+Shift+L: open (or put away) the chat history.
/// - Control+Shift+L: move the open chat (just that one) between Claude and the model on this Mac.
/// - Cmd+Shift+A: show or hide the agent bar (on key-up, so it can wait to see if V joins it).
/// Normal typing is never delayed: only the chord's final key is swallowed, so it never types into your document.
final class Hotkeys {
    var onSnip: (() -> Void)?
    var onChat: (() -> Void)?
    /// `true` when it's for the agents (⌘⇧A was already held).
    var onTalkStart: ((Bool) -> Void)?
    /// A was pressed while talking: what's being said is now a job for an agent.
    var onTalkAgent: (() -> Void)?
    var onTalkEnd: (() -> Void)?
    var onTasks: (() -> Void)?
    var onHistory: (() -> Void)?
    var onEngine: (() -> Void)?

    enum Action: Equatable { case snip, chat, talk, tasks, history, engine }

    private static let tabKey: Int64 = 48            // kVK_Tab
    private static let backslashKey: Int64 = 42      // kVK_ANSI_Backslash
    private static let vKey: Int64 = 9               // kVK_ANSI_V
    private static let lKey: Int64 = 37              // kVK_ANSI_L
    private static let aKey: Int64 = 0               // kVK_ANSI_A
    /// The talk key is down (touched only on the tap thread).
    private var talking = false
    /// A is down as part of ⌘⇧A or ⌘⇧V+A (its key-up is swallowed too).
    private var aHeld = false
    /// ⌘⇧A was pressed; the bar toggles when A comes up, unless V joined it first.
    private var tasksPending = false

    fileprivate var tap: CFMachPort?
    private var thread: Thread?
    /// The key whose keyDown we swallowed, so its keyUp is swallowed too.
    private var swallowedKey: Int64?

    /// Which chord (if any) a keyDown completes. `tabHeld` is whether Tab is physically down.
    static func action(keyCode: Int64, flags: CGEventFlags, tabHeld: Bool) -> Action? {
        if keyCode == backslashKey && tabHeld { return .snip }
        if keyCode == tabKey && flags.contains(.maskAlternate) && flags.contains(.maskShift)
            && !flags.contains(.maskCommand) && !flags.contains(.maskControl) { return .chat }
        let cmdShiftOnly = flags.contains(.maskCommand) && flags.contains(.maskShift)
            && !flags.contains(.maskAlternate) && !flags.contains(.maskControl)
        if keyCode == aKey && cmdShiftOnly { return .tasks }
        if keyCode == vKey && cmdShiftOnly { return .talk }
        if keyCode == lKey && cmdShiftOnly { return .history }
        if keyCode == lKey && flags.contains(.maskControl) && flags.contains(.maskShift)
            && !flags.contains(.maskCommand) && !flags.contains(.maskAlternate) { return .engine }
        return nil
    }

    /// Needs Accessibility permission; returns false without it.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
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
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass

        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            // While talking, the key's auto-repeats are swallowed even if Cmd or Shift were let go first. A fresh press
            // (not a repeat) can't happen while the key is still down, so it means a key-up was missed: let go, carry on.
            if talking && keyCode == Self.vKey {
                if isRepeat { return nil }
                talking = false
                DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
            }
            // ⌘⇧V+A: A while talking makes it a job for an agent.
            if talking && keyCode == Self.aKey {
                if !aHeld && !isRepeat { DispatchQueue.main.async { [weak self] in self?.onTalkAgent?() } }
                aHeld = true
                return nil
            }
            if aHeld && keyCode == Self.aKey {
                if isRepeat { return nil } // A held down
                aHeld = false // a fresh press means its key-up was missed: forget it, so a typed "a" is never swallowed
                tasksPending = false
            }
            let tabHeld = CGEventSource.keyState(.hidSystemState, key: CGKeyCode(Self.tabKey))
            guard let action = Self.action(keyCode: keyCode, flags: event.flags, tabHeld: tabHeld) else { return pass }
            if isRepeat { return nil }
            switch action {
            case .tasks:
                aHeld = true
                tasksPending = true
            case .talk:
                talking = true
                let forAgent = aHeld // ⌘⇧A+V
                tasksPending = false
                DispatchQueue.main.async { [weak self] in self?.onTalkStart?(forAgent) }
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
            if keyCode == Self.aKey && aHeld {
                aHeld = false
                if tasksPending {
                    tasksPending = false
                    DispatchQueue.main.async { [weak self] in self?.onTasks?() }
                }
                return nil
            }
            if keyCode == Self.vKey && talking {
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
