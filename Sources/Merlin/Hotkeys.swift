import AppKit

/// Merlin's global key chords, caught with one event tap on its own thread:
/// - Tab+\ (hold Tab, press \): snip an area of the screen.
/// - Option+Shift+Tab: open (or put away) a chat at the mouse.
/// - Hold Tab+Q (Tab first): talk to Merlin (let go of either key to send). It can also be one modifier key held on its
///   own, like Right ⌃ (see `ModifierHold`).
/// - Hold Shift on its own and move the pointer: point to ask (let go of Shift to ask about what you pointed at).
/// - Cmd+Shift+L: open (or put away) the chat history.
/// - Control+Shift+L: move the open chat (just that one) between Claude and the model on this Mac.
/// - Cmd+Shift+3/4/5 (macOS's screenshots) are never touched: Merlin just notes which app and window you were in, so the
///   screenshot that follows can be labeled by it.
/// Normal typing is never delayed: only the chord's final key is swallowed, so it never types into your document.
final class Hotkeys {
    var onSnip: (() -> Void)?
    var onChat: (() -> Void)?
    var onTalkStart: (() -> Void)?
    var onTalkEnd: (() -> Void)?
    /// Talk on a lone modifier was cut short by another key or a click: throw the recording away.
    var onTalkCancel: (() -> Void)?
    /// Point to ask (positions are screen points, top-left origin, as event taps give them).
    var onPointStart: ((_ from: CGPoint, _ to: CGPoint) -> Void)?
    var onPointMove: ((CGPoint) -> Void)?
    var onPointCancel: (() -> Void)?
    /// Shift was let go: ask about the trail. `withTalk` is true when talk was held at some moment during the gesture.
    var onPointEnd: ((_ withTalk: Bool) -> Void)?
    var onHistory: (() -> Void)?
    var onEngine: (() -> Void)?
    /// Settings → Shortcuts is recording a new chord: every key is left alone so the window can see it.
    nonisolated(unsafe) static var paused = false
    /// ⌘⇧3, ⌘⇧4 or ⌘⇧5 was pressed. It's macOS's own shortcut, so it's passed on untouched; Merlin only notes which window you're in.
    var onSystemShot: (() -> Void)?

    /// Tap Shift twice: add a screenshot of the screen to the open chat.
    var onDoubleShift: (() -> Void)?

    enum Action: String, CaseIterable, Equatable { case snip, chat, talk, history, engine }

    private static let tabKey: Int64 = 48            // kVK_Tab
    /// Shift, Control, Option, Command (left and right) and Fn.
    private static let modifierKeys: [Int64] = [54, 55, 56, 58, 59, 60, 61, 62, 63]
    /// The talk key is down (touched only on the tap thread).
    private var talking = false
    /// Two quick Shift taps (touched only on the tap thread).
    private var doubleShift = DoubleShift()

    fileprivate var tap: CFMachPort?
    private var thread: Thread?
    /// The key whose keyDown we swallowed, so its keyUp (and its auto-repeats) are swallowed too.
    private var swallowedKey: Int64?
    /// Talk started on a hold-Tab chord: Tab's auto-repeats and its key-up are swallowed until Tab is let go.
    private var swallowTab = false
    /// Talk held on one modifier key, and point to ask (touched only on the tap thread).
    private var talkHold = ModifierHold(keys: [], delay: 0.15)
    private var pointHold = ModifierHold(keys: [56, 60], delay: 0.2, minMove: 40)
    /// Talk was on at some moment during this point-to-ask gesture.
    private var pointSawTalk = false

    // What the tap reads from the outside world. The tests replace these, so no real key, clock or timer is involved.
    var store: KeybindStore = .shared
    /// Tab is physically down.
    var tabHeld: () -> Bool = { CGEventSource.keyState(.hidSystemState, key: CGKeyCode(48)) }
    /// The modifier keys physically down now.
    var modifiersHeld: () -> Set<Int64> = {
        Set(Hotkeys.modifierKeys.filter { CGEventSource.keyState(.hidSystemState, key: CGKeyCode($0)) })
    }
    /// Where the pointer is now (top-left origin).
    var pointer: () -> CGPoint = { CGEvent(source: nil)?.location ?? .zero }
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    /// Point to ask on or off, and which Shift keys start it.
    var pointSettings: () -> (on: Bool, keys: Set<Int64>) = {
        (Settings.shared.pointToAsk && !Settings.shared.paused, Settings.shared.pointToAskKey.keys)
    }
    /// Runs `work` after a delay on the current (tap) thread's run loop.
    var schedule: (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
        let timer = Timer(timeInterval: delay, repeats: false) { _ in work() }
        RunLoop.current.add(timer, forMode: .common)
    }

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
            // Point to ask follows the pointer while Shift is held, and a scroll or a middle click cancels it.
            | CGEventMask(1 << CGEventType.mouseMoved.rawValue) | CGEventMask(1 << CGEventType.scrollWheel.rawValue)
            | CGEventMask(1 << CGEventType.otherMouseDown.rawValue)
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
        thread.name = "merlin.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
        self.thread = thread
        return true
    }

    /// Runs on the tap thread (and in the unit tests, with made-up key events).
    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if Self.paused { return pass }
        // Every pointer move comes through here: do nothing at all unless point to ask is under way.
        switch type {
        case .mouseMoved:
            if pointHold.isBusy { pointerMoved(to: event.location) }
            return pass
        case .scrollWheel:
            if pointHold.isBusy { interruptPoint() }
            return pass
        default:
            break
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let binds = store.current
        let talkChord = binds.chord(.talk)
        let talkKey = talkChord.keyCode
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // A key-up may have been missed while the tap was off: drop any lone-modifier hold rather than guess.
            if talkHold.isActive { DispatchQueue.main.async { [weak self] in self?.onTalkCancel?() } }
            if pointHold.isActive { DispatchQueue.main.async { [weak self] in self?.onPointCancel?() } }
            talkHold.reset()
            pointHold.reset()
            return pass

        case .flagsChanged:
            // Shift on its own, twice, quickly. Nothing is swallowed: Shift still does what it always does.
            let f = event.flags
            let others = f.contains(.maskCommand) || f.contains(.maskAlternate) || f.contains(.maskControl)
            if doubleShift.flagsChanged(shift: f.contains(.maskShift), others: others, at: ProcessInfo.processInfo.systemUptime),
               binds.doubleShift {
                DispatchQueue.main.async { [weak self] in self?.onDoubleShift?() }
            }
            modifiersChanged(ModifierKeys.down(f.rawValue), talk: talkChord, at: pointer())
            return pass

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            doubleShift.interrupt() // a click means that Shift was for selecting
            interruptTalkHold()     // Option+click, Control+click: the click is yours, talk is dropped
            interruptPoint()        // Shift+click selects, as always
            return pass

        case .keyDown:
            doubleShift.interrupt() // a typed key means that Shift was for a capital or a chord
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat {
                interruptTalkHold() // Control+C while Control is the talk key: the copy happens, talk is dropped
                // A typed key ends point to ask, except the keys of a hold-Tab talk chord pressed while the trail is
                // already drawn (talking while pointing). Before that, Shift+Tab and a capital Q stay normal.
                let talkPart = pointHold.isActive && talkChord.holdTab
                    && (keyCode == Self.tabKey || (keyCode == talkKey && tabHeld()))
                if !talkPart { interruptPoint() }
            }
            // Talk on a hold-Tab chord: Tab's repeats would type a stream of tabs. A fresh Tab press means its key-up was missed.
            if swallowTab && keyCode == Self.tabKey {
                if isRepeat { return nil }
                swallowTab = false
            }
            // A key whose press we took: its repeats are ours too (Q after Tab was let go first). A fresh press starts over.
            if keyCode == swallowedKey {
                if isRepeat { return nil }
                swallowedKey = nil
            }
            // While talking, the key's auto-repeats are swallowed even if Cmd or Shift were let go first. A fresh press
            // (not a repeat) can't happen while the key is still down, so it means a key-up was missed: let go, carry on.
            if talking && keyCode == talkKey {
                if isRepeat { return nil }
                talking = false
                DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
            }
            if !isRepeat, Self.isSystemScreenshotChord(keyCode: keyCode, flags: event.flags) {
                DispatchQueue.main.async { [weak self] in self?.onSystemShot?() }
                return pass // macOS takes the screenshot; Merlin only notes where you were
            }
            // While pointing, Shift is held for point to ask, so a talk chord pressed then still counts.
            let flags = pointHold.isActive ? event.flags.subtracting(.maskShift) : event.flags
            guard let action = Self.action(keyCode: keyCode, flags: flags, tabHeld: tabHeld(), binds: binds) else { return pass }
            if isRepeat { return nil }
            switch action {
            case .talk:
                talking = true
                if talkChord.holdTab { swallowTab = true }
                if pointHold.isBusy { pointSawTalk = true }
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
            // Hold-Tab talk: letting go of Tab sends too. Tab's key-up is swallowed (it would type a tab), and so is the
            // other key's, still held.
            if keyCode == Self.tabKey && swallowTab {
                swallowTab = false
                if talking {
                    talking = false
                    swallowedKey = talkKey
                    DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
                }
                return nil
            }
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

    // MARK: Holding one modifier key (talk on a lone modifier, point to ask)

    /// The modifier keys changed (`down` is all of them, left and right apart). Nothing is ever swallowed here.
    private func modifiersChanged(_ down: Set<Int64>, talk: Chord, at location: CGPoint) {
        let t = now()
        // Point to ask first, so talk knows whether Shift belongs to it. Talk's own key never cancels pointing.
        let point = pointSettings()
        if point.on {
            if !pointHold.isBusy { pointHold.keys = point.keys }
            let talkKeys: Set<Int64> = talk.modifierKey.map { [$0] } ?? []
            let wasBusy = pointHold.isBusy
            switch pointHold.modifiers(down, ignoring: talkKeys, at: t, mouse: location) {
            case .end:
                let withTalk = pointSawTalk || talking || talkHold.isActive
                pointSawTalk = false
                DispatchQueue.main.async { [weak self] in self?.onPointEnd?(withTalk) }
            case .cancel:
                pointSawTalk = false
                DispatchQueue.main.async { [weak self] in self?.onPointCancel?() }
            case .none, .start:
                if !wasBusy && pointHold.isBusy { pointSawTalk = talking || talkHold.isActive }
            }
        } else if pointHold.isBusy {
            if pointHold.isActive { DispatchQueue.main.async { [weak self] in self?.onPointCancel?() } }
            pointHold.reset()
        }

        guard let key = talk.modifierKey else {
            if talkHold.isBusy { talkHold.reset() }
            return
        }
        talkHold.keys = [key]
        let wasPending = talkHold.phase == .pending
        switch talkHold.modifiers(down, ignoring: pointHold.isBusy ? pointHold.keys : [], at: t) {
        case .end:
            DispatchQueue.main.async { [weak self] in self?.onTalkEnd?() }
        case .cancel:
            DispatchQueue.main.async { [weak self] in self?.onTalkCancel?() }
        case .none, .start:
            if !wasPending && talkHold.phase == .pending {
                // A little after the hold is due, ask the rule again (on this same thread, so no locking is needed).
                schedule(talkHold.delay + 0.01) { [weak self] in self?.talkTick() }
            }
        }
    }

    /// The talk hold's timer. Talk starts only if the rule says so AND the key is still physically down (a missed key-up
    /// must never leave the microphone on with nobody holding the key).
    func talkTick() {
        guard talkHold.tick(at: now()) == .start else { return }
        guard !modifiersHeld().isDisjoint(with: talkHold.keys) else {
            talkHold.reset()
            return
        }
        if pointHold.isBusy { pointSawTalk = true }
        DispatchQueue.main.async { [weak self] in self?.onTalkStart?() }
    }

    private func pointerMoved(to location: CGPoint) {
        switch pointHold.tick(at: now(), mouse: location) {
        case .start:
            doubleShift.interrupt() // a Shift that pointed at something isn't half of a double tap
            let from = pointHold.startPoint
            DispatchQueue.main.async { [weak self] in self?.onPointStart?(from, location) }
        default:
            if pointHold.isActive { DispatchQueue.main.async { [weak self] in self?.onPointMove?(location) } }
        }
    }

    private func interruptPoint() {
        pointSawTalk = false
        if pointHold.interrupt() == .cancel { DispatchQueue.main.async { [weak self] in self?.onPointCancel?() } }
    }

    private func interruptTalkHold() {
        if talkHold.interrupt() == .cancel { DispatchQueue.main.async { [weak self] in self?.onTalkCancel?() } }
    }
}

private func hotkeysCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                             refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<Hotkeys>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
}
