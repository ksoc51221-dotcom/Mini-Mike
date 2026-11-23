import AppKit
import SwiftUI

/// The Library's Assistant card and the settings page's Assistant, clicked for real. The window is the app's own
/// (`LibraryWindow.makePanel` around `ThemedRoot { LibraryShell }`), on a throwaway library. Real mouse and key events are sent
/// to it at the spots where the buttons are drawn, and what happened is read back: the card's probe frame, its pixels, the
/// chat's text, the Library's state.
///
/// SwiftUI only answers clicks in a window that is ordered in, so the window is ordered in fully transparent, ignoring real
/// mouse clicks, never key, and placed 20,000 points beyond the edge of every display: nothing reaches any screen and your
/// typing and clicks are never touched.
extension FeatureTests {
    @MainActor
    static func assistantCardChecks(_ check: (String, Bool) -> Void) {
        guard CommandLine.arguments.contains("--unittest") else { return }
        _ = NSApplication.shared
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("merlin-assistantcard-\(UUID().uuidString)", isDirectory: true)
        let real = Library.shared.directory
        Library.shared.directory = tmp
        let suite = "merlin.assistantcard.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        var sent: [String] = []
        AssistantChat.debugSend = { sent.append($0) }
        DashboardProbe.enabled = true
        let chat = AssistantChat.shared
        let keptMessages = chat.messages, keptInput = chat.input
        defer {
            DashboardProbe.enabled = false
            DashboardProbe.frames = [:]
            AssistantChat.debugSend = nil
            chat.messages = keptMessages; chat.input = keptInput
            Library.shared.directory = real
            defaults.removePersistentDomain(forName: suite)
            try? fm.removeItem(at: tmp)
        }
        for (i, t) in ["Parabola direction", "Supply shift", "Opportunity cost"].enumerated() {
            var c = ChatRecord(title: t, sector: i == 1 ? "Economics" : "Math", app: "Safari", quote: "about \(t)",
                               turns: [.init(question: "Why?", answer: "Because \(t).")])
            c.updated = Date().addingTimeInterval(-Double(i) * 600)
            Library.shared.save(c, touch: false)
        }
        let sectors = SectorStore(directory: tmp.appendingPathComponent("sectors"), library: Library.shared)
        let shots = ProcessInfo.processInfo.environment["MERLIN_CARDSHOTS"].map { URL(fileURLWithPath: $0) }

        // A window saved too tall (as the bug left it) comes back fitted to the screen; a normal one is left alone.
        let screen = NSRect(x: 0, y: 0, width: 1512, height: 944) // a 14" MacBook's visible frame, menu bar and Dock taken off
        let grown = LibraryPanel.fitted(NSRect(x: 196, y: -1245, width: 1120, height: 2189), in: screen)
        check("window: a saved frame taller than the screen comes back on it, as tall as the screen",
              screen.contains(grown) && grown.height == screen.height && grown.width == 1120)
        let normal = NSRect(x: 196, y: 122, width: 1120, height: 700)
        check("window: a frame that fits is left exactly as it was", LibraryPanel.fitted(normal, in: screen) == normal)
        let offRight = LibraryPanel.fitted(NSRect(x: 1400, y: 100, width: 1120, height: 700), in: screen)
        check("window: a frame hanging off an edge is moved in, same size", screen.contains(offRight) && offRight.size == normal.size)
        let small = LibraryPanel.fitted(NSRect(x: 0, y: 0, width: 1120, height: 700), in: NSRect(x: 0, y: 0, width: 800, height: 480))
        check("window: on a screen smaller than the smallest window, it fills the screen", small == NSRect(x: 0, y: 0, width: 800, height: 480))

        for (size, asKey) in [(CGSize(width: 1120, height: 700), true), (CGSize(width: 920, height: 520), true), (CGSize(width: 1120, height: 700), false)] {
            let tag = "\(Int(size.width))x\(Int(size.height))" + (asKey ? "" : ", not key")
            let state = LibraryState()
            state.lastViewStore = Settings(defaults: defaults)
            state.settingsDataSource = { LibrarySettingsView.sampleData() }
            state.mode = .all
            state.browsing = true
            state.selection = Library.shared.chats.first.map { ItemRef(kind: .chat, id: $0.id) }
            let window = LibraryWindow.makePanel(ThemedRoot {
                LibraryShell(state: state, onAsk: { _, _ in }, sectorStore: sectors, answersStore: defaults)
            }, size: size)
            window.allowsKey = false
            window.actsKey = asKey // as when you click in it; your keyboard still goes to the app you're using
            window.keepsFrame = true
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            let farRight = NSScreen.screens.map(\.frame.maxX).max() ?? 0
            window.setFrameOrigin(NSPoint(x: farRight + 20_000, y: -20_000))
            window.orderFrontRegardless()
            check("assistant (\(tag)): the test window is on no display and can't take your keyboard",
                  !NSScreen.screens.contains { $0.frame.intersects(window.frame) } && !window.canBecomeKey && NSApp.keyWindow !== window
                  && window.alphaValue == 0)
            guard let host = window.contentView else { check("assistant (\(tag)): the window has content", false); continue }
            func settle(_ passes: Int = 6) { host.settleLayout(passes: passes, interval: 0.08) }
            settle(10)

            func frame(_ name: String) -> CGRect? { DashboardProbe.frames[name] }
            func send(_ type: NSEvent.EventType, at f: CGRect) {
                let p = NSPoint(x: f.midX, y: host.bounds.height - f.midY)
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                              pressure: type == .leftMouseDown ? 1 : 0) {
                    window.sendEvent(e)
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.06))
            }
            /// A real click (down, up) sent to the window at the middle of `name`'s frame (or of `at`).
            @discardableResult
            func click(_ name: String, at given: CGRect? = nil) -> Bool {
                guard let f = given ?? frame(name) else { return false }
                send(.leftMouseDown, at: f)
                send(.leftMouseUp, at: f)
                settle()
                return true
            }
            func key(_ code: UInt16, _ chars: String) {
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: window.windowNumber, context: nil, characters: chars,
                                                charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code) {
                        window.sendEvent(e)
                    }
                }
                settle(3)
            }
            /// How much of `rect` (clipped to the window) looks different between two pictures of the window (0...1).
            func changed(_ a: NSBitmapImageRep?, _ b: NSBitmapImageRep?, in rect: CGRect) -> Double {
                guard let a, let b, a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 0 }
                let r = rect.intersection(host.bounds)
                let scale = CGFloat(a.pixelsWide) / host.bounds.width
                var differ = 0, total = 0
                for y in stride(from: r.minY + 4, to: r.maxY - 4, by: 6) {
                    for x in stride(from: r.minX + 4, to: r.maxX - 4, by: 6) {
                        let px = Int(x * scale), py = Int(y * scale)
                        guard px < a.pixelsWide, py < a.pixelsHigh, let ca = a.colorAt(x: px, y: py), let cb = b.colorAt(x: px, y: py) else { continue }
                        total += 1
                        if abs(ca.redComponent - cb.redComponent) + abs(ca.greenComponent - cb.greenComponent) + abs(ca.blueComponent - cb.blueComponent) > 0.02 {
                            differ += 1
                        }
                    }
                }
                return total == 0 ? 0 : Double(differ) / Double(total)
            }
            /// Clicks the orb and reports whether the card came up, drawn, where it belongs.
            func openCard(_ label: String) -> Bool {
                let before = host.snapshotRep()
                guard click("assistant-orb") else { print("  [measure] \(tag) \(label): no orb frame"); return false }
                let card = frame("assistant-card")
                let after = host.snapshotRep()
                if let shots {
                    for (n, r) in [("before", before), ("after", after)] {
                        try? r?.representation(using: .png, properties: [:])?
                            .write(to: shots.appendingPathComponent("\(tag)-\(label.replacingOccurrences(of: " ", with: "-"))-\(n).png"))
                    }
                }
                let diff = card.map { changed(before, after, in: $0) } ?? 0
                let onWindow = card.map { $0.minY >= 0 && $0.maxY <= host.bounds.height && $0.height > 300 } ?? false
                print("  [measure] \(tag) \(label): orb at \(frame("assistant-orb").map { "\($0.integral)" } ?? "-"), "
                      + "card \(card.map { "\($0.integral)" } ?? "absent"), \(Int(diff * 100))% of its area changed in the window's picture")
                return card != nil && onWindow && diff > 0.08
            }

            /// Every settings section in turn, then back: the window must keep its size and its smallest size throughout.
            func sizesHold(_ label: String) -> Bool {
                var heights: [(String, CGFloat)] = []
                for section in LibrarySettingsView.Section.allCases {
                    state.openSettings(section: section); settle(5)
                    heights.append((section.rawValue, window.frame.height))
                }
                state.closeSettings(); settle(5)
                heights.append(("library", window.frame.height))
                print("  [measure] \(tag) \(label): window height by page: " + heights.map { "\($0.0) \(Int($0.1))" }.joined(separator: ", ")
                      + "; resizing stops at \(window.delegate?.windowWillResize?(window, to: NSSize(width: 600, height: 300)) ?? .zero)")
                let smallest = window.delegate?.windowWillResize?(window, to: NSSize(width: 600, height: 300)) ?? .zero
                return heights.allSatisfy { abs($0.1 - size.height) < 1 } && smallest == LibraryPanel.floor
            }

            // 0. Sanity: real clicks reach SwiftUI buttons in this window at all (the list's "Select").
            click("select-mode")
            check("assistant (\(tag)): a real click reaches a plain Library button (Select)", state.selecting)
            state.selecting = false; settle()

            // 1. A fresh window that has never shown the settings. (Every section is visited once at the end, in 7.)
            check("assistant (\(tag)): the orb opens the card in a fresh window", openCard("fresh window"))
            click("assistant-orb")
            check("assistant (\(tag)): clicking the orb again closes it", frame("assistant-card") == nil)
            // Every settings section once (the Assistant section is the one that used to grow the window), then back.
            check("assistant (\(tag)): no settings section resizes the window (first visit)", sizesHold("first visit"))

            // 2. Settings opened, then back to the Library with "‹ Library": what the owner did.
            state.openSettings(); settle(8)
            click("settings-back")
            check("assistant (\(tag)): \"‹ Library\" brings the Library back", state.page == .library)
            settle(4)
            check("assistant (\(tag)): after Settings and back, the orb still opens the card", openCard("after settings and back"))

            // 3. Typing into the card goes to its text box; Return sends; no Library shortcut takes the keys.
            let searchBefore = state.searchFocus, moveBefore = state.moveRequest, selectionBefore = state.selection
            chat.input = ""
            sent = []
            for (code, ch) in [(UInt16(4), "h"), (34, "i")] { key(code, ch) }
            check("assistant (\(tag)): the card's text box takes typed letters (got “\(chat.input)”)", chat.input == "hi")
            key(36, "\r")
            check("assistant (\(tag)): Return sends what was typed", sent == ["hi"] && chat.input.isEmpty)
            check("assistant (\(tag)): no Library shortcut fired while typing", state.searchFocus == searchBefore && state.moveRequest == moveBefore
                  && state.selection == selectionBefore)

            // 4. Esc closes the card, and only the card: the Library stays where it was (not sent to the Desk).
            key(53, "\u{1b}")
            check("assistant (\(tag)): Esc closes the card", frame("assistant-card") == nil)
            check("assistant (\(tag)): ...without sending the Library to the Desk", !state.isDesk && state.page == .library && state.selection == selectionBefore)

            // 5. With the settings showing, the Library's orb (hidden underneath) does nothing; the page's own Assistant works.
            let orbSpot = frame("assistant-orb")
            state.openSettings(); settle(8)
            if let orbSpot { click("", at: orbSpot) }
            check("assistant (\(tag)): with Settings showing, the hidden Library's card doesn't open", frame("assistant-card") == nil)
            check("assistant (\(tag)): the settings page's own Assistant opens from its sidebar",
                  click("settings-assistant-orb") && state.settingsSection == .assistant && frame("settings-assistant") != nil)
            chat.input = ""
            sent = []
            for (code, ch) in [(UInt16(17), "t"), (31, "o")] { key(code, ch) }
            key(36, "\r")
            check("assistant (\(tag)): ...and takes typing and Return there (got “\(sent.first ?? chat.input)”)", sent == ["to"])

            print("  [measure] \(tag) settings Assistant in use: window \(window.frame.size), content \(host.bounds.size), minSize \(window.minSize), "
                  + "settings Assistant pane \(frame("settings-assistant").map { "\($0.integral)" } ?? "-"), orb \(frame("assistant-orb").map { "\($0.integral)" } ?? "-")")
            // 6. Back from the settings page's Assistant to the Library, then the Library's orb.
            click("settings-back"); settle(4)
            check("assistant (\(tag)): after using the settings page's Assistant and going back, the orb opens the card",
                  state.page == .library && openCard("after the settings Assistant and back"))
            chat.input = ""
            sent = []
            for (code, ch) in [(UInt16(4), "h"), (34, "i")] { key(code, ch) }
            check("assistant (\(tag)): ...and the card's text box has the keys, not the hidden page's (got “\(chat.input)”)", chat.input == "hi")
            key(53, "\u{1b}")
            state.closeSettings(); settle(8)

            // 7. The window keeps its size whatever the page shows, with a conversation in the Assistant (the case that grew it).
            check("assistant (\(tag)): no settings section resizes the window", sizesHold("with a conversation"))
            window.orderOut(nil)
            window.close()
        }
    }
}
