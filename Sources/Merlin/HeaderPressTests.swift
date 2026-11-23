import AppKit
import SwiftUI

extension FeatureTests {
    /// The chat header: a press that doesn't move is a click for the control under it (the Learn switch, star, size, close);
    /// a press that moves drags the window and clicks nothing. Sent as real mouse events through `ChatPanel.sendEvent`
    /// into the real `AskView`, in a window that is never put on screen.
    @MainActor
    static func headerPressChecks(_ check: (String, Bool) -> Void) {
        // The rule itself.
        var p = HeaderPress()
        p.down(at: NSPoint(x: 100, y: 100))
        check("header press: under 4 points of movement is not a drag", p.moved(to: NSPoint(x: 102, y: 102)) == nil && p.isHeld)
        check("header press: ...and letting go makes it a click", p.up() && !p.isHeld)
        p.down(at: NSPoint(x: 100, y: 100))
        check("header press: 4 points or more starts a drag, by how far it moved", p.moved(to: NSPoint(x: 110, y: 100)) == NSPoint(x: 10, y: 0))
        check("header press: a drag stays a drag even back at the start", p.moved(to: NSPoint(x: 100, y: 100)) == NSPoint(x: 0, y: 0))
        check("header press: letting go after a drag is not a click", !p.up())
        check("header press: a release with no press is nothing", !p.up() && p.moved(to: .zero) == nil)

        savedLearn(check)
        // Real events into the real header. SwiftUI only answers clicks in a window that is ordered in (a window that was never
        // shown gets none: checked), so this part orders the chat in fully transparent and click-through, and is skipped by
        // MERLIN_HEADLESS_TESTS=1.
        guard ProcessInfo.processInfo.environment["MERLIN_HEADLESS_TESTS"] == nil else { return }
        let blank = Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: blank, footnote: "Sonnet")
        model.learnMode = false
        var stars = 0, sizes = 0, closes = 0, learnWrites: [Bool] = []
        model.onToggleStar = { stars += 1 }
        model.onToggleSize = { sizes += 1 }
        model.onClose = { closes += 1 }
        model.onLearnChange = { learnWrites.append($0) }
        model.isLarge = false
        let size = NSSize(width: model.width, height: 320) // as wide as the chat draws itself
        let panel = ChatPanel(size: size, canKey: false)
        let host = NSHostingView(rootView: ThemedRoot { AskView(model: model) })
        host.frame = NSRect(origin: .zero, size: size)
        panel.contentView = host
        panel.setFrame(NSRect(x: 200, y: 200, width: size.width, height: size.height), display: false)
        panel.alphaValue = 0 // invisible
        panel.ignoresMouseEvents = true // your real clicks pass through it
        panel.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        func event(_ type: NSEvent.EventType, _ at: NSPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        func click(_ at: NSPoint) {
            panel.sendEvent(event(.leftMouseDown, at))
            panel.sendEvent(event(.leftMouseUp, at))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        // Walk the header row and note where each control answers (so the test doesn't hard-code the layout).
        var learnSpot: NSPoint?, starSpot: NSPoint?, sizeSpot: NSPoint?, closeSpot: NSPoint?
        for fromTop in stride(from: CGFloat(18), through: 34, by: 4) {
            for x in stride(from: CGFloat(12), through: size.width - 8, by: 4) {
                let at = NSPoint(x: x, y: size.height - fromTop)
                guard panel.startsDrag(at: at) else { continue }
                let before = (model.learnMode, stars, sizes, closes)
                click(at)
                if model.learnMode != before.0, learnSpot == nil { learnSpot = at }
                if stars != before.1, starSpot == nil { starSpot = at }
                if sizes != before.2, sizeSpot == nil { sizeSpot = at }
                if closes != before.3, closeSpot == nil { closeSpot = at }
            }
        }
        check("header click: a click on the Learn switch toggles Learn (it sits in the drag zone)", learnSpot != nil && !learnWrites.isEmpty)
        check("header click: ...and the switch is at the left of the header", (learnSpot?.x ?? 999) < size.width / 2)
        check("header click: the size button gets its click", sizeSpot != nil)
        check("header click: the close button gets its click", closeSpot != nil)
        if Settings.shared.saveHistory { check("header click: the star button gets its click", starSpot != nil) }
        check("header click: empty header space clicks nothing", {
            let before = (model.learnMode, stars, sizes, closes)
            click(NSPoint(x: size.width / 2, y: size.height - 26))
            return (model.learnMode, stars, sizes, closes) == before
        }())

        // Three clicks on the switch change it three times.
        if let spot = learnSpot {
            let start = model.learnMode
            click(spot); let one = model.learnMode
            click(spot); let two = model.learnMode
            click(spot); let three = model.learnMode
            check("header click: three clicks on the switch change it each time", one != start && two == start && three != start)

            // A drag that starts on the switch moves the window and leaves Learn alone.
            let learnBefore = model.learnMode, origin = panel.frame.origin
            panel.sendEvent(event(.leftMouseDown, spot))
            panel.sendEvent(event(.leftMouseDragged, NSPoint(x: spot.x + 10, y: spot.y)))
            let moved = panel.frame.origin
            // (the window has moved under the pointer, so the same screen point is now 10 points left in window terms)
            panel.sendEvent(event(.leftMouseUp, spot))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            check("header drag: a 10-point drag from the switch moves the window 10 points", abs(moved.x - origin.x - 10) < 0.5 && abs(moved.y - origin.y) < 0.5)
            check("header drag: ...and Learn is unchanged", model.learnMode == learnBefore)
            panel.sendEvent(event(.leftMouseDown, spot))
            panel.sendEvent(event(.leftMouseDragged, NSPoint(x: spot.x + 2, y: spot.y)))
            panel.sendEvent(event(.leftMouseUp, NSPoint(x: spot.x + 2, y: spot.y)))
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            check("header drag: a 2-point wobble is still a click, and the window stays put", model.learnMode != learnBefore && panel.frame.origin == moved)
        }
        panel.orderOut(nil)
    }

    /// A new chat starts from the saved Learn value (`AskPanelController` reads `Settings.learnMode` when it makes the chat).
    private static func savedLearn(_ check: (String, Bool) -> Void) {
        let suite = "merlin.headerpress.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = Settings(defaults: defaults)
        check("learn saved: off when never set", settings.learnMode == false)
        settings.learnMode = true
        check("learn saved: a second reader of the same store sees on", Settings(defaults: defaults).learnMode)
    }
}
