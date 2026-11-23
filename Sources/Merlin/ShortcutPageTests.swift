import AppKit
import SwiftUI

/// What the page shows and holds while it's hosted in a real window (an off-screen one that is never shown), and a flag
/// the tests flip to say "the Library is showing again" or "switch section", as the Library window does.
final class ShortcutPageFlag: ObservableObject {
    @Published var active = true
    @Published var section = LibrarySettingsView.Section.shortcuts
}

private struct ShortcutPageHost: View {
    @ObservedObject var flag: ShortcutPageFlag
    let directory: URL
    var body: some View {
        LibrarySettingsView(section: .shortcuts, data: LibrarySettingsView.sampleData(),
                            sectorStore: SectorStore(directory: directory, library: Library(directory: directory)),
                            sectionBinding: Binding(get: { flag.section }, set: { flag.section = $0 }), onBack: {}, active: flag.active)
    }
}

extension FeatureTests {
    /// The Shortcuts page at the Library's smallest window (920 × 520), in a window that never leaves memory.
    @MainActor
    private static func offscreenSettings(flag: ShortcutPageFlag, size: CGSize = CGSize(width: 920, height: 520))
        -> (window: NSWindow, host: NSHostingView<ShortcutPageHost>, scroll: () -> NSScrollView?) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-shortcutpage-\(UUID().uuidString)")
        let host = NSHostingView(rootView: ShortcutPageHost(flag: flag, directory: dir))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.settleLayout(passes: 5, interval: 0.1)
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return (window, host, { find(host) })
    }

    @MainActor
    static func shortcutPageChecks(_ check: (String, Bool) -> Void) {
        guard CommandLine.arguments.contains("--unittest") else { return } // it writes to KeybindStore.shared, which is in memory only then
        _ = NSApplication.shared
        let store = KeybindStore.shared
        store.resetAll()
        Hotkeys.paused = false
        defer { store.resetAll(); Hotkeys.paused = false }

        // 1. "Go to" scrolls the real page. A clash between the first row ("Snip the screen") and the last ("Back to the Library").
        store.set(ShortcutCommand.libraryBack.defaultChord, for: .snip)
        let flag = ShortcutPageFlag()
        let page = offscreenSettings(flag: flag)
        guard let scroll = page.scroll() else { check("page: the settings page has a scroll view", false); return }
        func post(_ info: [String: String]) { NotificationCenter.default.post(name: .merlinShortcutsPage, object: nil, userInfo: info) }
        func settle() { page.host.settleLayout(passes: 12, interval: 0.1) }
        func offset() -> CGFloat { scroll.contentView.bounds.origin.y }
        let start = offset()
        let visible = scroll.contentView.bounds.height
        let docHeight = scroll.documentView?.frame.height ?? 0
        let farthest = docHeight - visible
        post(["jump": ShortcutCommand.libraryBack.id]); settle()
        let bottom = offset()
        post(["jump": ShortcutCommand.snip.id]); settle()
        let top = offset()
        post(["jump": ShortcutCommand.libraryNewChat.id]); settle()
        let middle = offset()
        print("  [measure] 920x520 window: page \(docHeight)pt tall, window shows \(visible)pt; scroll offset at start \(start), "
              + "after jump to the last row \(bottom), back to the first row \(top), to a middle row \(middle)")
        check("page: the page is taller than the smallest window, so there is something to scroll", docHeight > visible + 200)
        check("page: it starts at the top", start == 0)
        check("page: 'Go to' the last row scrolls down to the end", bottom > 100 && abs(bottom - farthest) < 2)
        check("page: 'Go to' the first row scrolls back to the top", top == 0)
        check("page: 'Go to' a middle row lands in between", middle > 100 && middle < farthest - 20)
        store.resetAll()

        // 3. Recording and the page around it. Events go through NSApp.sendEvent, where the local monitors run first.
        func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags = []) {
            let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: page.window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                     isARepeat: false, keyCode: code)!
            NSApp.sendEvent(e)
        }
        func record() { post(["record": ShortcutCommand.libraryMove.id]); settle() }
        let moveDefault = ShortcutCommand.libraryMove.defaultChord
        record()
        check("recording: starting it pauses the global shortcuts", Hotkeys.paused)
        key(53, "\u{1b}"); settle()
        check("recording: Esc only cancels it (and the shortcuts work again)", !Hotkeys.paused && store.current.chord(.libraryMove) == moveDefault)
        key(33, "[", .command); settle()
        check("recording: with no recording, ⌘[ is left alone for the window", store.current.chord(.libraryMove) == moveDefault)
        record()
        key(33, "[", .command); settle()
        check("recording: ⌘[ is taken as the new chord, not as 'back'",
              store.current.chord(.libraryMove) == Chord(keyCode: 33, command: true) && !Hotkeys.paused
              && store.current.rivals(of: .libraryMove) == [.libraryBack])
        store.resetAll()

        record()
        flag.active = false; settle() // "‹ Library" (or Esc, or ⌘[): the page goes back behind the Library
        check("recording: going back to the Library stops it", !Hotkeys.paused)
        key(38, "j", .command); settle()
        check("recording: and the page no longer listens to keys", store.current.chord(.libraryMove) == moveDefault)
        flag.active = true; settle()

        record()
        page.window.close(); settle()
        check("recording: closing the window stops it", !Hotkeys.paused)
        flag.active = true

        record()
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp); settle()
        check("recording: leaving the app stops it", !Hotkeys.paused)

        record()
        flag.section = .general; settle() // a deep link switches the section while recording
        check("recording: switching section stops it", !Hotkeys.paused)
        check("recording: nothing was changed by any of that", store.current.isDefault)
    }
}
