import AppKit

/// Watches global mouse events and reports when the user has probably just highlighted text.
final class SelectionWatcher {
    /// Selection plus the mouse-up point (Cocoa screen coordinates).
    var onSelection: ((Selection, NSPoint) -> Void)?
    /// The user clicked, typed or scrolled somewhere else.
    var onDismissSignal: (() -> Void)?

    private var monitors: [Any] = []
    private var downPoint: NSPoint = .zero
    private var dragged = false
    private var generation = 0

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard monitors.isEmpty else { return }
        add(.leftMouseDown) { [weak self] e in self?.mouseDown(e) }
        add(.leftMouseDragged) { [weak self] _ in self?.mouseDragged() }
        add(.leftMouseUp) { [weak self] e in self?.mouseUp(e) }
        add([.rightMouseDown, .scrollWheel]) { [weak self] _ in self?.onDismissSignal?() }
        add(.keyDown) { [weak self] e in
            if Date() < SelectionReader.syntheticCopyUntil, e.keyCode == 8, e.modifierFlags.contains(.command) { return }
            self?.generation += 1
            self?.onDismissSignal?()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func add(_ mask: NSEvent.EventTypeMask, _ handler: @escaping (NSEvent) -> Void) {
        if let m = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(m)
        }
    }

    private func mouseDown(_ e: NSEvent) {
        downPoint = NSEvent.mouseLocation
        dragged = false
        generation += 1
        onDismissSignal?()
    }

    private func mouseDragged() {
        let p = NSEvent.mouseLocation
        if hypot(p.x - downPoint.x, p.y - downPoint.y) > 6 { dragged = true }
    }

    private func mouseUp(_ e: NSEvent) {
        let looksLikeSelection = dragged || e.clickCount >= 2 || e.modifierFlags.contains(.shift)
        guard looksLikeSelection, !Settings.shared.paused, !Snipper.isActive,
              let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !Settings.shared.excludedBundleIDs.contains(app.bundleIdentifier ?? "") else { return }

        let point = NSEvent.mouseLocation
        generation += 1
        let gen = generation
        // Give the app a moment to finalize the selection (double-click word snapping etc).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, gen == self.generation else { return }
            SelectionReader.read(app: app, mouse: point) { [weak self] selection in
                guard let self, gen == self.generation, let selection else { return }
                self.onSelection?(selection, point)
            }
        }
    }
}
