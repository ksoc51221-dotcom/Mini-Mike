import AppKit

/// Checks that a chat's glow rests while the chat is still, and catches up at once when the chat moves, resizes, fades or hides.
/// The test window sits far off every screen, so nothing shows.
enum GlowTests {
    static func run(_ check: (String, Bool) -> Void) {
        _ = NSApplication.shared
        let panel = NSWindow(contentRect: NSRect(x: -30_000, y: -30_000, width: 300, height: 200), styleMask: .borderless, backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.orderFront(nil)
        let glow = PanelGlow(around: panel, cornerRadius: 12)
        func aligned() -> Bool { glow.debugFrame == panel.frame.insetBy(dx: -PanelGlow.reach, dy: -PanelGlow.reach) }
        func faded() -> Bool { abs(glow.debugAlpha - 0.4) < 0.01 }
        func rest() { FeatureTests.pump(PanelGlow.settle + 1.5) { glow.debugIdle } }

        glow.popped()
        check("glow: it appears around the chat", glow.debugVisible && aligned() && !glow.debugIdle)
        rest()
        check("glow: it rests once the chat has been still", glow.debugIdle)

        panel.setFrame(NSRect(x: -30_000, y: -30_000, width: 340, height: 260), display: false)
        check("glow: a resize is followed at once, and wakes it", aligned() && !glow.debugIdle)
        rest()
        panel.setFrameOrigin(NSPoint(x: -29_900, y: -29_950))
        let movedAtOnce = aligned()
        FeatureTests.pump(0.3) { aligned() }
        check("glow: a move is followed", aligned())
        rest()
        panel.alphaValue = 0.4
        let fadedAtOnce = faded()
        FeatureTests.pump(0.3) { faded() }
        check("glow: a fade is followed", faded())
        rest()
        // The way the chat really fades: through the animator.
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.12; panel.animator().alphaValue = 1 }
        FeatureTests.pump(0.05) { !glow.debugIdle }
        let wokeForAnimatedFade = !glow.debugIdle
        FeatureTests.pump(0.6) { abs(glow.debugAlpha - 1) < 0.01 }
        check("glow: an animated fade wakes it within 50 ms and is followed to the end", wokeForAnimatedFade && abs(glow.debugAlpha - 1) < 0.01)
        rest()
        panel.orderOut(nil)
        let hidAtOnce = !glow.debugVisible
        FeatureTests.pump(0.3) { glow.debugStopped }
        check("glow: it leaves with the chat and stops its timer", !glow.debugVisible && glow.debugStopped)
        print("  [measure] glow follows at once: move \(movedAtOnce), fade \(fadedAtOnce), hide \(hidAtOnce)")

        glow.popped() // before the chat is on screen
        panel.orderFront(nil)
        FeatureTests.pump(0.3) { glow.debugVisible }
        check("glow: it comes back when the chat is shown again, even if told first", glow.debugVisible && aligned())
        panel.orderOut(nil)
        FeatureTests.pump(0.3) { glow.debugStopped }
        glow.remove()
    }
}
