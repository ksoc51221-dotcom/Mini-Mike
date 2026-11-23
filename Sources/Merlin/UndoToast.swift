import AppKit
import SwiftUI

/// "Moved to Bin · Undo": a small bar that floats near a chat you just closed, for a few seconds, and takes clicks
/// (the plain `Toast` ignores the mouse, so it can't carry an Undo).
enum UndoToast {
    private static var panel: FloatingPanel?
    private static var hideWork: DispatchWorkItem?
    static let seconds: TimeInterval = 6

    /// Shows `text` with an Undo button under `rect` (the closed chat's frame). `onUndo` runs once, then the bar goes away.
    static func show(_ text: String, near rect: NSRect, undoID: UUID, onUndo: @escaping () -> Void) {
        hide(animated: false)
        let size = NSSize(width: 300, height: 40)
        let view = UndoBar(toast: LibraryState.Toast(text: text, undo: [undoID]),
                           onUndo: { onUndo(); hide(animated: true) },
                           onClose: { hide(animated: true) })
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let p = FloatingPanel(size: size, canKey: false)
        p.contentView = host
        let screen = NSScreen.screens.first { NSMouseInRect(NSPoint(x: rect.midX, y: rect.midY), $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        let x = min(max(rect.midX - size.width / 2, vf.minX + 8), vf.maxX - size.width - 8)
        let y = max(rect.minY - size.height - 8, vf.minY + 8)
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()
        panel = p
        let work = DispatchWorkItem { hide(animated: true) }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func hide(animated: Bool) {
        hideWork?.cancel(); hideWork = nil
        guard let p = panel else { return }
        panel = nil
        guard animated else { p.orderOut(nil); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            p.animator().alphaValue = 0
        }, completionHandler: { p.orderOut(nil) })
    }

    static var isShowing: Bool { panel != nil }
}
