import AppKit
import Foundation
import SwiftUI

extension FeatureTests {
    /// --bintest: the dashboard's clear button and the Bin, end to end, on a throwaway library. Nothing of yours is touched and
    /// nothing shows: the window is invisible, passes your clicks through, and never takes the keyboard. Real clicks are sent to the
    /// window at the spots where the buttons are drawn: every row in the Notebook, Chats, Screenshots and All lists must have a clear
    /// button on its right; pressing it moves that thing to the Bin and offers Undo; the Bin lists it with Restore and Delete forever.
    /// (The Delete-key part needs the keyboard for a moment, so it only runs with MARGIN_BINTEST_KEYS=1, and then the window shows.)
    static func liveBinTest() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print((ok ? "ok   " : "FAIL ") + name)
            if !ok { failures += 1 }
        }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("margin-bintest-live-\(UUID().uuidString)", isDirectory: true)
        let real = Library.shared.directory
        Library.shared.directory = tmp
        DashboardProbe.enabled = true
        func finish() -> Never {
            LibraryWindow.shared.debugWindow?.orderOut(nil)
            DashboardProbe.enabled = false
            Library.shared.directory = real
            try? fm.removeItem(at: tmp)
            print(failures == 0 ? "BINTEST PASS" : "BINTEST FAIL (\(failures))")
            exit(failures == 0 ? 0 : 1)
        }

        // A few of everything.
        for (i, t) in ["Parabola direction", "Supply shift", "Opportunity cost"].enumerated() {
            var c = ChatRecord(title: t, sector: i == 1 ? "Economics" : "Math", app: "Safari", quote: "about \(t)",
                               turns: [.init(question: "Why?", answer: "Because \(t).")])
            c.updated = Date().addingTimeInterval(-Double(i) * 600)
            Library.shared.save(c, touch: false)
            var n = Note(title: t, sector: "Math", app: "Safari", quote: "q", question: "Question \(i + 1) about \(t)?", body: "Answer \(i + 1).")
            n.created = Date().addingTimeInterval(-Double(i) * 600)
            Library.shared.add(n)
        }
        for (i, t) in ["BIDV history", "Teams cover work"].enumerated() {
            var r = ScreenshotRecord(created: Date().addingTimeInterval(-Double(i) * 600), title: t)
            r.text = t
            if let jpeg = Snipper.downscaledJPEG(wordsPNG(t, width: 600, height: 300)) { _ = Library.shared.writeScreenshotImage(jpeg, for: r) }
            Library.shared.add(r)
        }
        let notesBefore = Library.shared.notes.count, chatsBefore = Library.shared.chats.count, shotsBefore = Library.shared.screenshots.count
        let everything = chatsBefore + notesBefore + shotsBefore
        func total() -> Int { Library.shared.chats.count + Library.shared.notes.count + Library.shared.screenshots.count }

        let live = LibraryWindow.shared
        let state = live.debugState
        let wantsKeys = ProcessInfo.processInfo.environment["MARGIN_BINTEST_KEYS"] != nil
        live.quiet = !wantsKeys
        live.show(mode: .notebook, takeKeyboard: false)
        live.debugClickThrough(true) // your own clicks go through it, to whatever is below
        if let w = live.debugWindow, let vf = NSScreen.main?.visibleFrame { // bottom-right, out of the way
            w.setFrameOrigin(NSPoint(x: max(vf.minX, vf.maxX - w.frame.width - 20), y: vf.minY + 20))
        }

        /// Waits (up to `seconds`) until `condition` holds, letting the window redraw meanwhile.
        func pump(_ seconds: Double, until condition: () -> Bool) async {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end, !condition() { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        func frame(_ name: String) -> CGRect? { DashboardProbe.frames[name] }
        /// A real click, sent to the window where `name` is drawn.
        @discardableResult
        func click(_ name: String) -> Bool {
            guard let f = frame(name), let w = live.debugWindow, let height = w.contentView?.bounds.height else { return false }
            let p = NSPoint(x: f.midX, y: height - f.midY)
            let t = ProcessInfo.processInfo.systemUptime
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: t, windowNumber: w.windowNumber, context: nil,
                                              eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) { w.sendEvent(e) }
            }
            return true
        }
        func ids(_ prefix: String) -> Set<UUID> {
            Set(DashboardProbe.frames.keys.filter { $0.hasPrefix(prefix + ":") }.compactMap { UUID(uuidString: String($0.dropFirst(prefix.count + 1))) })
        }
        /// Each row's button sits on the right half of its row, level with it.
        func onTheRight(_ id: UUID, _ action: String) -> Bool {
            guard let card = frame("card:\(id)"), let button = frame("\(action):\(id)") else { return false }
            return button.minX > card.midX && button.maxX <= card.maxX && abs(button.midY - card.midY) < card.height / 2
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            check("bin: the dashboard never took the keyboard", live.debugWindow?.isKeyWindow == false && !NSRunningApplication.current.isActive)
            check("bin: Margin isn't the app in front (whatever you were using still is)", NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier)

            // Notebook: a clear button on the right of every row.
            await pump(3) { ids("clear").count == notesBefore }
            let noteIDs = Set(Library.shared.notes.map(\.id))
            check("notebook: every note has a clear button (\(ids("clear").count) buttons for \(notesBefore) notes)", ids("clear") == noteIDs && notesBefore == 3)
            check("notebook: ...on the right of its row", noteIDs.allSatisfy { onTheRight($0, "clear") })
            let note = Library.shared.notes.first!
            check("notebook: clicking the first one", click("clear:\(note.id)"))
            await pump(2) { Library.shared.notes.count == notesBefore - 1 }
            check("notebook: the note leaves the notebook", Library.shared.notes.count == notesBefore - 1 && !Library.shared.notes.contains { $0.id == note.id })
            check("notebook: ...and is in the Bin", Library.shared.binItem(note.id)?.kind == .note)
            await pump(2) { frame("undo") != nil }
            check("notebook: a message offers Undo", state.toast != nil && frame("undo") != nil)
            click("undo")
            await pump(2) { Library.shared.notes.count == notesBefore }
            check("notebook: Undo puts the note back", Library.shared.notes.count == notesBefore && Library.shared.binItem(note.id) == nil)
            check("notebook: the message goes away", state.toast == nil)

            // Chats, screenshots and All have them too.
            state.mode = .chats
            let chatIDs = Set(Library.shared.chats.map(\.id))
            await pump(3) { ids("clear") == chatIDs }
            await pump(0.3) { false }
            check("chats: every chat has a clear button, on the right of its row", ids("clear") == chatIDs && chatIDs.allSatisfy { onTheRight($0, "clear") })
            state.mode = .screenshots
            let shotIDs = Set(Library.shared.screenshots.map(\.id))
            await pump(3) { ids("clear") == shotIDs }
            await pump(0.3) { false }
            check("screenshots: every screenshot has a clear button, on the right of its row", ids("clear") == shotIDs && shotIDs.allSatisfy { onTheRight($0, "clear") })
            state.mode = .all
            await pump(3) { ids("clear") == chatIDs.union(noteIDs).union(shotIDs) }
            await pump(0.3) { false }
            check("all: every row, whatever it is, has one", ids("clear") == chatIDs.union(noteIDs).union(shotIDs))

            // Clear a chat from All, then find it in the Bin.
            let chat = Library.shared.chats.first!
            click("clear:\(chat.id)")
            await pump(2) { Library.shared.chats.count == chatsBefore - 1 }
            check("all: clearing a chat there moves it to the Bin", total() == everything - 1 && Library.shared.binItem(chat.id)?.kind == .chat)
            state.mode = .bin
            await pump(3) { ids("restore") == [chat.id] }
            await pump(0.3) { false } // let the list settle before clicking where things are
            check("bin: it's listed with Restore and Delete forever on its row", ids("restore") == [chat.id] && ids("forever") == [chat.id]
                  && onTheRight(chat.id, "restore") && onTheRight(chat.id, "forever"))
            click("restore:\(chat.id)")
            await pump(2) { Library.shared.binned.isEmpty }
            check("bin: Restore puts it back", Library.shared.binned.isEmpty && total() == everything && Library.shared.chat(chat.id) != nil)

            // Delete forever, with the Bin's own filter.
            let victim = Library.shared.screenshots.first!
            Library.shared.delete(screenshot: victim.id)
            Library.shared.delete(note: note.id)
            await pump(3) { ids("forever") == [victim.id, note.id] }
            await pump(0.3) { false }
            check("bin: a screenshot and a note are listed", ids("forever") == [victim.id, note.id])
            state.kind = .screenshot
            await pump(3) { ids("forever") == [victim.id] }
            await pump(0.3) { false }
            check("bin: Shots shows only the screenshot", ids("forever") == [victim.id])
            click("forever:\(victim.id)")
            await pump(2) { Library.shared.binItem(victim.id) == nil }
            Library.shared.flush()
            check("bin: Delete forever deletes it for good, picture too", Library.shared.binItem(victim.id) == nil
                  && !fm.fileExists(atPath: Library.shared.imageURL(for: victim).path))
            check("bin: ...and leaves the rest of the Bin alone", Library.shared.binItem(note.id) != nil)
            state.kind = nil
            Library.shared.restore(note.id)

            // The Delete key: with the list in front, it moves the selected row to the Bin. (The window takes the keyboard for a moment.)
            if !wantsKeys {
                print("skip keys: arrows, Delete and Edit > Delete (run with MARGIN_BINTEST_KEYS=1; the window is visible and takes the keyboard for a moment)")
                finish()
            }
            state.mode = .notebook
            await pump(3) { ids("card") == Set(Library.shared.notes.map(\.id)) }
            await pump(0.3) { false }
            let target = Library.shared.notes.first!
            live.debugAllowKey(true)
            live.debugWindow?.makeKeyAndOrderFront(nil)
            await pump(1) { live.debugWindow?.isKeyWindow == true }
            click("card:\(target.id)")
            await pump(1) { state.selection?.id == target.id }
            check("keys: clicking a row selects it", state.selection == ItemRef(kind: .note, id: target.id))
            await pump(1) { DashboardProbe.listFocused }
            check("keys: the list has the keyboard after a click", DashboardProbe.listFocused)
            await pump(0.4) { false }
            /// A key press, sent straight to the window as the keyboard would.
            @MainActor func press(_ chars: String, keyCode: UInt16) {
                guard let w = live.debugWindow else { return }
                for type in [NSEvent.EventType.keyDown, .keyUp] {
                    if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                                isARepeat: false, keyCode: keyCode) { NSApp.sendEvent(e) }
                }
            }
            let notesNow = Library.shared.notes.map(\.id)
            press("\u{F701}", keyCode: 125) // down arrow
            await pump(1) { state.selection?.id != target.id }
            check("keys: the down arrow moves to the next row", state.selection?.id == notesNow.dropFirst().first)
            press("\u{F700}", keyCode: 126) // up arrow
            await pump(1) { state.selection?.id == target.id }
            check("keys: the up arrow moves back", state.selection?.id == target.id)
            press("\u{8}", keyCode: 51) // Backspace
            await pump(2) { Library.shared.binItem(target.id) != nil }
            check("keys: the Delete key moves the selected note to the Bin", Library.shared.binItem(target.id)?.kind == .note)
            check("keys: ...and the next note is shown instead", state.selection != nil && state.selection?.id != target.id)
            let second = state.selection!.id
            // The Edit menu's Delete (what AppKit sends down the chain for a Backspace nothing else took).
            NSApp.sendAction(#selector(NSText.delete(_:)), to: nil, from: nil)
            await pump(2) { Library.shared.binItem(second) != nil }
            check("keys: Delete from the Edit menu does the same", Library.shared.binItem(second)?.kind == .note)
            Library.shared.restore(target.id)
            Library.shared.restore(second)
            finish()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 90) { print("BINTEST FAIL: timed out"); exit(2) }
        app.run()
        exit(0)
    }
}
