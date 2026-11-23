import AppKit
import SwiftUI

extension FeatureTests {
    /// R5, a free chat size: the edge zones and resize maths, fill and back, the saved size and its migration from the old
    /// "make bigger" switch, and (windowed) real drags on a real chat window.
    @MainActor
    static func resizeChecks(_ check: (String, Bool) -> Void) {
        typealias R = PanelResize
        let size = CGSize(width: 400, height: 300)

        // Zones.
        check("resize zone: the right edge", R.zone(at: CGPoint(x: 398, y: 150), in: size) == .right)
        check("resize zone: the left edge", R.zone(at: CGPoint(x: 2, y: 150), in: size) == .left)
        check("resize zone: the bottom edge", R.zone(at: CGPoint(x: 200, y: 2), in: size) == .bottom)
        check("resize zone: the bottom-left corner (along both edges)",
              R.zone(at: CGPoint(x: 2, y: 2), in: size) == .bottomLeft && R.zone(at: CGPoint(x: 12, y: 2), in: size) == .bottomLeft
              && R.zone(at: CGPoint(x: 2, y: 12), in: size) == .bottomLeft)
        check("resize zone: the bottom-right corner (along both edges)",
              R.zone(at: CGPoint(x: 398, y: 2), in: size) == .bottomRight && R.zone(at: CGPoint(x: 388, y: 2), in: size) == .bottomRight
              && R.zone(at: CGPoint(x: 398, y: 12), in: size) == .bottomRight)
        check("resize zone: the band is 6 pt deep (7 pt in is content)",
              R.zone(at: CGPoint(x: 7, y: 150), in: size) == nil && R.zone(at: CGPoint(x: 393, y: 150), in: size) == nil
              && R.zone(at: CGPoint(x: 200, y: 7), in: size) == nil)
        check("resize zone: the middle is not a zone", R.zone(at: CGPoint(x: 200, y: 150), in: size) == nil)
        check("resize zone: the top edge is not a zone", R.zone(at: CGPoint(x: 200, y: 299), in: size) == nil)
        check("resize zone: the header wins in the top 40 pt, even on a side edge",
              R.zone(at: CGPoint(x: 2, y: 270), in: size) == nil && R.zone(at: CGPoint(x: 398, y: 261), in: size) == nil
              && R.zone(at: CGPoint(x: 2, y: 260), in: size) == .left)
        check("resize zone: outside the window is nothing", R.zone(at: CGPoint(x: -1, y: 150), in: size) == nil)

        // Resize maths (screen coordinates, origin bottom-left).
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let start = CGRect(x: 400, y: 300, width: 400, height: 300)
        let right = R.resized(start, zone: .right, by: CGPoint(x: 100, y: 37), within: screen)
        check("resize: the right edge widens by the drag, the rest stays", right == CGRect(x: 400, y: 300, width: 500, height: 300))
        let left = R.resized(start, zone: .left, by: CGPoint(x: -100, y: 0), within: screen)
        check("resize: a left-edge drag keeps the right edge fixed", left == CGRect(x: 300, y: 300, width: 500, height: 300))
        let bottom = R.resized(start, zone: .bottom, by: CGPoint(x: 0, y: -50), within: screen)
        check("resize: a bottom drag keeps the top edge fixed", bottom == CGRect(x: 400, y: 250, width: 400, height: 350))
        let corner = R.resized(start, zone: .bottomLeft, by: CGPoint(x: -20, y: -30), within: screen)
        check("resize: the bottom-left corner moves both, keeping the top-right fixed",
              corner == CGRect(x: 380, y: 270, width: 420, height: 330))
        let cornerR = R.resized(start, zone: .bottomRight, by: CGPoint(x: 20, y: -30), within: screen)
        check("resize: the bottom-right corner keeps the top-left fixed", cornerR == CGRect(x: 400, y: 270, width: 420, height: 330))
        let tiny = R.resized(start, zone: .bottomRight, by: CGPoint(x: -1000, y: 1000), within: screen)
        check("resize: the minimum 360 × 260 holds", tiny.size == R.minSize && tiny.minX == 400 && tiny.maxY == 600)
        let tinyLeft = R.resized(start, zone: .left, by: CGPoint(x: 1000, y: 0), within: screen)
        check("resize: ...also from the left, with the right edge still fixed", tinyLeft.width == 360 && tinyLeft.maxX == 800)
        let huge = R.resized(start, zone: .right, by: CGPoint(x: 5000, y: 0), within: screen)
        check("resize: the right edge stops at the screen's edge", huge.maxX == screen.maxX && huge.minX == 400)
        let hugeLeft = R.resized(start, zone: .bottomLeft, by: CGPoint(x: -5000, y: -5000), within: screen)
        check("resize: the left and bottom edges stop at the screen's edges", hugeLeft.minX == 0 && hugeLeft.minY == 0 && hugeLeft.maxX == 800 && hugeLeft.maxY == 600)
        let full = CGRect(x: 0, y: 0, width: 400, height: 875)
        let biggest = R.resized(full, zone: .right, by: CGPoint(x: 9000, y: 0), within: screen)
        check("resize: never larger than the visible screen", biggest.width <= screen.width && biggest.height <= screen.height)
        let fitted = R.fit(CGRect(x: 1300, y: -40, width: 2000, height: 2000), into: screen, margin: 8)
        check("resize: a size bigger than the screen is trimmed to it and put inside", fitted == screen)
        let inside = R.fit(CGRect(x: 1200, y: 200, width: 400, height: 300), into: screen, margin: 8)
        check("resize: a chat off the screen's side comes back inside, 8 pt from the edge", inside == CGRect(x: 1032, y: 200, width: 400, height: 300))

        // Fill and back.
        var fill = FillToggle()
        let before = CGRect(x: 123, y: 456, width: 420, height: 333)
        let filled = fill.toggle(current: before, manual: false, screen: screen)
        check("fill: ⤢ fills the visible screen, as a fixed size", filled.frame == screen && filled.manual && fill.isFilled)
        let back = fill.toggle(current: screen, manual: true, screen: screen)
        check("fill: ⤢ again goes back to the exact earlier frame, and to the auto size it had", back.frame == before && !back.manual && !fill.isFilled)
        _ = fill.toggle(current: before, manual: true, screen: screen)
        fill.forget()
        check("fill: a hand resize while filled forgets the earlier size", !fill.isFilled)
        check("fill: back from fill to a size set by hand keeps it set by hand", {
            var f = FillToggle()
            _ = f.toggle(current: before, manual: true, screen: screen)
            return f.toggle(current: screen, manual: true, screen: screen) == (before, true)
        }())

        // Auto-growth.
        check("auto size: with no size set by hand the chat grows with its answer",
              AskPanelController.followsContent(manualSize: nil, viewIsManual: false))
        check("auto size: a size set by hand turns growth off",
              !AskPanelController.followsContent(manualSize: CGSize(width: 500, height: 400), viewIsManual: false)
              && !AskPanelController.followsContent(manualSize: nil, viewIsManual: true))

        // The start size.
        typealias S = ChatStartSize
        check("start size: nothing saved is the default width", S.resolve(saved: nil, isVideo: false, screen: screen) == nil)
        check("start size: a sane saved width carries over (the height never does: it fits the content)",
              S.resolve(saved: CGSize(width: 500, height: 900), isVideo: false, screen: screen) == 500
              && AskPanelController.width == S.defaultWidth)
        check("start size: a video always starts at its large auto size",
              S.resolve(saved: CGSize(width: 500, height: 900), isVideo: true, screen: screen) == nil
              && S.resolve(saved: CGSize(width: 800, height: 600), isVideo: true, screen: screen) == nil)
        check("start size: a saved width under the minimum opens at the minimum",
              S.resolve(saved: CGSize(width: 100, height: 100), isVideo: false, screen: screen) == R.minSize.width)
        check("start size: an oversize saved value (a filled screen) opens at the default width",
              S.resolve(saved: CGSize(width: 1440, height: 875), isVideo: false, screen: screen) == nil
              && S.resolve(saved: CGSize(width: 611, height: 260), isVideo: false, screen: screen) == nil
              && S.resolve(saved: CGSize(width: 2000, height: 300), isVideo: false, screen: screen) == nil)
        check("start size: the limit is 1.5 x the default and 60% of the screen",
              S.resolve(saved: CGSize(width: 570, height: 660), isVideo: false, screen: screen) == 570
              && S.resolve(saved: CGSize(width: 500, height: 400), isVideo: false, screen: CGRect(x: 0, y: 0, width: 800, height: 600)) == nil)
        check("start size: an invalid saved width is rejected",
              S.resolve(saved: CGSize(width: CGFloat.nan, height: 400), isVideo: false, screen: screen) == nil
              && S.resolve(saved: CGSize(width: CGFloat.infinity, height: 400), isVideo: false, screen: screen) == nil)
        do {
            // After an oversize value opens a chat at the default width, a hand resize still works and is saved.
            let opened = CGRect(x: 400, y: 300, width: S.defaultWidth, height: 200)
            let dragged = R.resized(opened, zone: .bottomRight, by: CGPoint(x: 120, y: -150), within: screen)
            check("start size: a hand resize still works after an oversize value was rejected",
                  dragged.size == CGSize(width: S.defaultWidth + 120, height: 350)
                  && S.shouldSave(size: dragged.size, startedFilled: false, screen: screen)
                  && !S.shouldSave(size: CGSize(width: 900, height: 400), startedFilled: false, screen: screen)
                  && S.resolve(saved: dragged.size, isVideo: false, screen: screen) == S.defaultWidth + 120)
        }
        do {
            // Fill, then drag an edge: the chat keeps its new size, but new chats don't start from it.
            var f = FillToggle()
            let filledTo = f.toggle(current: CGRect(x: 400, y: 300, width: 380, height: 200), manual: false, screen: screen)
            let startedFilled = f.isFilled
            f.forget()
            let dragged = R.resized(filledTo.frame, zone: .right, by: CGPoint(x: -40, y: 0), within: screen)
            check("fill: a drag that starts on a filled chat is not saved for the next chat",
                  startedFilled && !S.shouldSave(size: CGSize(width: 400, height: 300), startedFilled: startedFilled, screen: screen))
            check("fill: a filled size saved by an old build still opens the next chat at the default width",
                  S.resolve(saved: dragged.size, isVideo: false, screen: screen) == nil)
        }

        // Saved size and the one-time migration from `largePopup`.
        func store(_ body: (UserDefaults) -> Void) -> (Settings, UserDefaults, String) {
            let suite = "merlin.resize.test.\(UUID().uuidString)"
            let d = UserDefaults(suiteName: suite)!
            body(d)
            return (Settings(defaults: d), d, suite)
        }
        do {
            let (s, d, suite) = store { $0.set(true, forKey: "largePopup") }
            defer { d.removePersistentDomain(forName: suite) }
            check("migration: largePopup on and no saved size → the old big size, 570 wide", s.chatSize == Settings.largeChatSize && s.chatSize?.width == 570)
            s.chatSize = nil
            check("migration: ...only once (cleared later, it stays cleared)", s.chatSize == nil && Settings(defaults: d).chatSize == nil)
        }
        do {
            let (s, d, suite) = store { $0.set(false, forKey: "largePopup") }
            defer { d.removePersistentDomain(forName: suite) }
            check("migration: largePopup off → nothing saved", s.chatSize == nil)
        }
        do {
            let (s, d, suite) = store {
                $0.set(true, forKey: "largePopup")
                $0.set(700.0, forKey: Settings.chatWidthKey); $0.set(450.0, forKey: Settings.chatHeightKey)
            }
            defer { d.removePersistentDomain(forName: suite) }
            check("migration: a saved size is kept", s.chatSize == CGSize(width: 700, height: 450))
        }
        do {
            let (s, d, suite) = store { _ in }
            defer { d.removePersistentDomain(forName: suite) }
            s.chatSize = CGSize(width: 640, height: 480)
            check("saved size: a second reader of the same store sees it (640 is too wide, so the next chat ignores it)",
                  Settings(defaults: d).chatSize == CGSize(width: 640, height: 480)
                  && ChatStartSize.resolve(saved: Settings(defaults: d).chatSize, isVideo: false, screen: screen) == nil) // 640 > 570
            s.chatSize = CGSize(width: 500, height: 480)
            check("saved size: a sane saved width is what the next chat starts at",
                  ChatStartSize.resolve(saved: Settings(defaults: d).chatSize, isVideo: false, screen: screen) == 500)
            let spec = LibraryAssistant.settingSpecs.first { $0.key == "largePopup" }
            check("assistant setting: largePopup reads on while a size is saved", spec?.read(s) == "on")
            check("assistant setting: off clears the saved size", spec?.write(s, "off") == true && s.chatSize == nil && spec?.read(s) == "off")
            check("assistant setting: on saves the old big size", spec?.write(s, "on") == true && s.chatSize == Settings.largeChatSize)
            check("assistant setting: nonsense is refused", spec?.write(s, "maybe") == false)
        }

        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        windowedResize(check)
    }

    /// Real mouse events into a real chat window (transparent, click-through), as in `headerPressChecks`. Every press here
    /// starts on the outer 6 pt edge band or on empty header space or on a header button, never on a text field.
    @MainActor
    private static func windowedResize(_ check: (String, Bool) -> Void) {
        let blank = Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: blank, footnote: "Sonnet")
        model.learnMode = false
        let panel = ChatPanel(size: NSSize(width: model.width, height: 320), canKey: false)
        var sizes = 0, fills = 0, resizes = 0, ends = 0
        model.onToggleSize = { sizes += 1 }
        model.onHeaderTap = { if panel.headerClickCount == 2 { fills += 1 } } // as AskPanelController wires it
        panel.onResized = { ended in resizes += 1; if ended { ends += 1; model.isManualSize = true } }
        let host = NSHostingView(rootView: ThemedRoot { AskView(model: model) })
        host.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.autoresizingMask = [.width, .height]
        let content = NSView(frame: host.frame)
        content.addSubview(host)
        panel.contentView = content
        let vf = panel.visibleArea
        panel.setFrame(NSRect(x: vf.minX + 200, y: vf.minY + 200, width: model.width, height: 320), display: false)
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        /// `screen` is a screen point; the event carries it in the window's current coordinates.
        func send(_ type: NSEvent.EventType, _ screen: NSPoint, clicks: Int = 1) {
            let at = NSPoint(x: screen.x - panel.frame.minX, y: screen.y - panel.frame.minY)
            panel.sendEvent(NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: clicks,
                                               pressure: type == .leftMouseUp ? 0 : 1)!)
        }
        func drag(from a: NSPoint, by d: NSPoint) {
            send(.leftMouseDown, a)
            for i in 1...5 {
                let f = CGFloat(i) / 5
                send(.leftMouseDragged, NSPoint(x: a.x + d.x * f, y: a.y + d.y * f))
            }
            send(.leftMouseUp, NSPoint(x: a.x + d.x, y: a.y + d.y))
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        func click(_ screen: NSPoint, clicks: Int) {
            send(.leftMouseDown, screen, clicks: clicks)
            send(.leftMouseUp, screen, clicks: clicks)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }

        // A click on the edge that doesn't move is not a size set by hand.
        var f = panel.frame
        click(NSPoint(x: f.maxX - 2, y: f.minY + 120), clicks: 1)
        check("resize (real events): a click on the edge with no movement changes nothing", panel.frame == f && resizes == 0 && ends == 0)

        // A real drag on the right edge (2 pt inside it, halfway down the part below the header).
        drag(from: NSPoint(x: f.maxX - 2, y: f.minY + 120), by: NSPoint(x: 60, y: 0))
        check("resize (real events): a drag on the right edge widens the chat by the drag",
              abs(panel.frame.width - (f.width + 60)) < 0.5 && panel.frame.minX == f.minX && panel.frame.maxY == f.maxY)
        check("resize (real events): ...and reports the size, with the end of the drag", resizes > 0 && ends == 1)
        f = panel.frame
        drag(from: NSPoint(x: f.minX + 2, y: f.minY + 120), by: NSPoint(x: -40, y: 0))
        check("resize (real events): a drag on the left edge keeps the right edge", abs(panel.frame.width - (f.width + 40)) < 0.5 && abs(panel.frame.maxX - f.maxX) < 0.5)
        f = panel.frame
        drag(from: NSPoint(x: f.maxX - 2, y: f.minY + 2), by: NSPoint(x: -1000, y: 1000))
        check("resize (real events): a drag past the minimum stops at 360 × 260",
              panel.frame.size == PanelResize.minSize && panel.frame.minX == f.minX && panel.frame.maxY == f.maxY)
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        check("resize (real events): the chat's content follows the window's size", abs(host.frame.width - panel.frame.width) < 0.5)

        // The header still moves the window (empty header space, middle of the row).
        f = panel.frame
        let empty = NSPoint(x: f.midX, y: f.maxY - 26)
        drag(from: empty, by: NSPoint(x: 10, y: -10))
        check("resize (real events): the header still moves the window, without resizing it",
              abs(panel.frame.minX - f.minX - 10) < 0.5 && abs(panel.frame.minY - f.minY + 10) < 0.5 && panel.frame.size == f.size)
        check("resize (real events): moving the window is not a resize", ends == 3)

        // A double-click on empty header space fills (once); a single click does nothing.
        f = panel.frame
        let mid = NSPoint(x: f.midX, y: f.maxY - 26)
        click(mid, clicks: 1)
        let afterSingle = fills
        click(mid, clicks: 2)
        check("double-click (real events): a single click on the header fills nothing", afterSingle == 0)
        check("double-click (real events): a double-click on empty header space fills the screen", fills == 1 && sizes == 0)

        // The ⤢ button: find it along the header row, then double-click it. Two button clicks, no extra fill.
        var sizeSpot: NSPoint?
        for x in stride(from: f.maxX - 8, through: f.midX, by: -4) {
            let at = NSPoint(x: x, y: f.maxY - 26)
            let before = sizes
            click(at, clicks: 1)
            if sizes != before { sizeSpot = at; break }
        }
        check("header click (real events): the ⤢ button gets its click in a resized chat", sizeSpot != nil)
        if let spot = sizeSpot {
            let (s0, f0) = (sizes, fills)
            RunLoop.current.run(until: Date().addingTimeInterval(0.6)) // past the double-click interval
            click(spot, clicks: 1)
            click(spot, clicks: 2)
            check("double-click (real events): a double-click on ⤢ is two button clicks and no header fill", sizes == s0 + 2 && fills == f0)
        }
        panel.orderOut(nil)
    }
}
