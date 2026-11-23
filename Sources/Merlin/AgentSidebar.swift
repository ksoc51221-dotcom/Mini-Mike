import AppKit

/// The black sidebar where agents rest, like the chat list in Claude: one row per chat with its
/// circle, its title and what it's doing. It sits at the top-right of the laptop screen, has room for
/// every agent, and can fold down to a slim strip of dots.
final class AgentSidebar {
    struct Row {
        let id: ObjectIdentifier
        var title: String
        var subtitle: String
        var phase: AgentPhase
        /// This chat is the one open on screen right now.
        var isOpen: Bool
        /// The chat's star (shown on the row, and clickable there).
        var starred = false
        var canStar = false
    }

    var onSelect: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?
    var onStar: ((ObjectIdentifier) -> Void)?

    // Geometry (points).
    static let width: CGFloat = 244
    static let stripWidth: CGFloat = 36
    static let margin: CGFloat = 10
    fileprivate static let headerHeight: CGFloat = 40
    static let headerHeightForDrag: CGFloat = 40
    fileprivate static let rowHeight: CGFloat = 52
    fileprivate static let rowPitch: CGFloat = 54
    fileprivate static let rowInset: CGFloat = 8
    fileprivate static let bottomPad: CGFloat = 8
    fileprivate static let disc: CGFloat = 28
    /// Where the circle's center sits inside a row.
    fileprivate static let discX: CGFloat = 24
    /// Where a row's title starts (the header's "Chats" lines up with it, and its spark with the circles).
    fileprivate static let textX: CGFloat = 48

    private let panel: SidebarPanel
    private let content = SidebarView(frame: NSRect(x: 0, y: 0, width: AgentSidebar.width, height: 100))
    private var rows: [Row] = []
    private var views: [ObjectIdentifier: RowView] = [:]
    private(set) var isOpen: Bool

    init(open: Bool = Settings.shared.sidebarOpen) {
        isOpen = open
        panel = SidebarPanel(size: NSSize(width: Self.width, height: 100))
        panel.contentView = content
        content.onToggle = { [weak self] in self?.toggle() }
        content.setOpen(open, animated: false)
        // The header (and, when folded, the whole strip) is a handle: drag the sidebar anywhere, and it stays there.
        panel.dragZone = { [weak self] p in self?.startsDrag(at: p) ?? false }
        panel.onDragEnded = { [weak self] in self?.dragEnded() }
        panel.onReset = { [weak self] in self?.resetPosition() }
    }

    /// Where a press may start dragging the sidebar: the header (not its fold button), or any of the folded strip.
    func startsDrag(at p: NSPoint) -> Bool {
        let fromTop = panel.frame.height - p.y
        if !isOpen { return true }
        return fromTop < Self.headerHeight && p.x < panel.frame.width - 44
    }

    /// The sidebar was dropped somewhere: remember its top-right corner (so it grows downward and keeps its edge).
    private func dragEnded() {
        let f = panel.frame
        Settings.shared.sidebarAnchor = NSPoint(x: f.maxX, y: f.maxY)
        panel.invalidateShadow()
    }

    /// Double-click the header: back to the top-right corner of the laptop screen.
    func resetPosition() {
        Settings.shared.sidebarAnchor = nil
        arrange(animated: true)
    }

    /// Moves the sidebar as a drag would (for tests).
    func debugDrag(by delta: NSSize) {
        panel.setFrameOrigin(NSPoint(x: panel.frame.minX + delta.width, y: panel.frame.minY + delta.height))
        dragEnded()
    }

    /// Drags it with real mouse events through the window, like the header does. False if that spot isn't a handle.
    func debugDragHeader(by delta: NSSize) -> Bool {
        let local = NSPoint(x: 60, y: panel.frame.height - 20)
        guard startsDrag(at: local) else { return false }
        panel.debugPlayDrag(from: local, by: delta)
        return true
    }
    var debugHasSavedPosition: Bool { Settings.shared.sidebarAnchor != nil }

    /// Double-clicks the header with real mouse events (it should put the sidebar back in its corner).
    func debugDoubleClickHeader() -> Bool {
        let local = NSPoint(x: 60, y: panel.frame.height - 20)
        guard startsDrag(at: local) else { return false }
        for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
            guard let e = NSEvent.mouseEvent(with: type, location: local, modifierFlags: [],
                                             timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: panel.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: count, pressure: 1) else { return false }
            panel.sendEvent(e)
        }
        return true
    }

    var frame: NSRect { panel.frame }

    // MARK: - Rows

    /// Brings the sidebar in line with the agents (call whenever any of them changes).
    func sync(_ newRows: [Row]) {
        let ids = Set(newRows.map(\.id))
        for (id, view) in views where !ids.contains(id) {
            views[id] = nil
            view.leave()
        }
        for row in newRows {
            if let view = views[row.id] {
                view.apply(row)
            } else {
                let view = RowView(id: row.id)
                view.onSelect = { [weak self] id in self?.onSelect?(id) }
                view.onDelete = { [weak self] id in self?.onDelete?(id) }
                view.onStar = { [weak self] id in self?.onStar?(id) }
                view.apply(row)
                views[row.id] = view
                content.addSubview(view)
                view.isHidden = !isOpen
                view.frame = rowFrame(newRows.firstIndex { $0.id == row.id } ?? 0)
                if isOpen { view.arrive() }
            }
        }
        rows = newRows
        content.setDots(newRows.map { ($0.phase, $0.isOpen) })
        content.setCount(newRows.count, of: Settings.shared.maxAgents)
        arrange(animated: true)
    }

    private func rowFrame(_ index: Int) -> NSRect {
        NSRect(x: Self.rowInset, y: Self.headerHeight + CGFloat(index) * Self.rowPitch,
               width: Self.width - Self.rowInset * 2, height: Self.rowHeight)
    }

    // MARK: - Open / closed

    func toggle() { setOpen(!isOpen) }

    func setOpen(_ open: Bool) {
        guard open != isOpen else { return }
        isOpen = open
        Settings.shared.sidebarOpen = open
        content.setOpen(open, animated: true)
        for view in views.values { view.isHidden = !open }
        if open { for view in views.values { view.arrive() } }
        arrange(animated: true)
    }

    // MARK: - Placement

    private func size(open: Bool, count: Int) -> NSSize {
        guard open else {
            return NSSize(width: Self.stripWidth, height: SidebarView.stripHeight(count: count))
        }
        return NSSize(width: Self.width, height: Self.headerHeight + CGFloat(count) * Self.rowPitch + Self.bottomPad)
    }

    /// Where the sidebar is (or is moving to): where you dragged it, or else the top-right corner of the laptop screen.
    private func targetFrame() -> NSRect {
        let s = size(open: isOpen, count: max(rows.count, 1))
        return Self.frame(size: s, anchor: Settings.shared.sidebarAnchor, screens: NSScreen.screens.map(\.visibleFrame),
                          dockScreen: Self.dockScreen?.visibleFrame)
    }

    /// The sidebar's frame for a size. Its top-right corner stays put as it grows or folds, and it's kept on a screen
    /// (the one the corner is on; if that screen is gone, the laptop's). Pure, so it's tested.
    static func frame(size s: NSSize, anchor: NSPoint?, screens: [NSRect], dockScreen: NSRect?) -> NSRect {
        let fallback = dockScreen ?? screens.first ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        guard let anchor else {
            return NSRect(x: fallback.maxX - margin - s.width, y: fallback.maxY - margin - s.height, width: s.width, height: s.height)
        }
        // The screen whose area holds the corner (a little slack for the edge itself).
        let home = screens.first { $0.insetBy(dx: -2, dy: -2).contains(anchor) } ?? fallback
        var x = anchor.x - s.width
        var y = anchor.y - s.height
        x = min(max(x, home.minX + 4), home.maxX - s.width - 4)
        y = min(max(y, home.minY + 4), home.maxY - s.height - 4)
        return NSRect(x: x, y: y, width: s.width, height: s.height)
    }

    private func arrange(animated: Bool) {
        if rows.isEmpty {
            guard panel.isVisible else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, self.rows.isEmpty else { return }
                self.panel.orderOut(nil)
            })
            // Belt and braces: the fade's completion can arrive late, and an empty sidebar should always go away.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                guard let self, self.rows.isEmpty, self.panel.isVisible else { return }
                self.panel.orderOut(nil)
            }
            return
        }
        let target = targetFrame()
        for (i, row) in rows.enumerated() {
            guard let view = views[row.id] else { continue }
            let frame = rowFrame(i)
            if animated && panel.isVisible {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.25
                    ctx.timingFunction = Motion.easeOut
                    view.animator().frame = frame
                }
            } else {
                view.frame = frame
            }
        }
        if !panel.isVisible || panel.alphaValue < 1 {
            if !panel.isVisible {
                panel.alphaValue = 0
                panel.setFrame(target.offsetBy(dx: 14, dy: 0), display: false)
                panel.orderFrontRegardless()
            }
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = Motion.easeOut
                panel.animator().alphaValue = 1
            }
            WindowMotion.animate(panel, to: target, duration: 0.22) { [weak self] in self?.panel.invalidateShadow() }
        } else if animated {
            WindowMotion.animate(panel, to: target, duration: 0.25) { [weak self] in self?.panel.invalidateShadow() }
        } else {
            panel.setFrame(target, display: true)
        }
    }

    /// Screen rect of a row's circle: what a chat shrinks into and grows back out of. When the sidebar is
    /// folded it's that agent's dot instead.
    func discFrame(at index: Int) -> NSRect {
        let t = targetFrame()
        if isOpen {
            let d = Self.disc
            let cx = t.minX + Self.rowInset + Self.discX
            let cy = t.maxY - (Self.headerHeight + CGFloat(index) * Self.rowPitch + Self.rowHeight / 2)
            return NSRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d)
        }
        let d = SidebarView.dotSize
        let cy = t.maxY - SidebarView.dotCenterY(index)
        return NSRect(x: t.midX - d / 2, y: cy - d / 2, width: d, height: d)
    }

    /// A moment of emphasis on a row (a chat just landed in it).
    func flash(_ id: ObjectIdentifier) { views[id]?.flash() }

    /// The built-in laptop display if there is one, otherwise the main display.
    static var dockScreen: NSScreen? {
        NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.screens.first
    }

    // MARK: - Debug hooks (--demo, --placetest)

    /// Where each row's circle and aura actually are on screen, and where the circle should be.
    var debugRows: [(disc: NSPoint, aura: NSPoint, expected: NSPoint)] {
        rows.enumerated().compactMap { i, row in
            guard let view = views[row.id], let window = view.window else { return nil }
            func screenCenter(_ v: NSView) -> NSPoint {
                let r = window.convertToScreen(v.convert(v.bounds, to: nil))
                return NSPoint(x: r.midX, y: r.midY)
            }
            let want = discFrame(at: i)
            return (screenCenter(view.discView), screenCenter(view.discView), NSPoint(x: want.midX, y: want.midY))
        }
    }
    var debugPanelFrame: NSRect { panel.frame }
    var debugIsVisible: Bool { panel.isVisible }
    func debugTitles() -> [String] { rows.map(\.title) }
    func debugFlashAll() { views.keys.forEach(flash) }
    var debugRowCount: Int { rows.count }
    func debugClickRow(_ index: Int) { if rows.indices.contains(index) { onSelect?(rows[index].id) } }
    func debugClickDelete(_ index: Int) { if rows.indices.contains(index) { onDelete?(rows[index].id) } }

    /// The sidebar as it looks right now, over a backdrop (the windows' blur and shadow can't be captured).
    func debugSnapshot(backdrop: NSColor = NSColor(white: 0.30, alpha: 1)) -> NSBitmapImageRep? {
        let pad: CGFloat = 16
        let size = NSSize(width: panel.frame.width + pad * 2, height: panel.frame.height + pad * 2)
        guard let rep = NSBitmapImageRep.rgba(pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2)) else { return nil }
        rep.size = size
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext else { return nil }
        ctx.setFillColor(backdrop.cgColor)
        ctx.fill(CGRect(origin: .zero, size: size))
        ctx.translateBy(x: pad, y: size.height - pad) // the card is a flipped view; draw it top-down
        ctx.scaleBy(x: 1, y: -1)
        (content.layer?.presentation() ?? content.layer)?.render(in: ctx)
        return rep
    }
}

// MARK: - Headless picture (--uishots)

extension AgentSidebar {
    /// The sidebar card with these rows, drawn without a window (so nothing appears on screen). The blur and shadow of the
    /// real window aren't part of it; the card itself is the same views.
    @MainActor
    static func shotImage(titles: [(title: String, subtitle: String, phase: AgentPhase, isOpen: Bool)], open: Bool = true) -> CGImage? {
        let count = max(titles.count, 1)
        let size = open ? NSSize(width: width, height: headerHeight + CGFloat(count) * rowPitch + bottomPad)
                        : NSSize(width: stripWidth, height: SidebarView.stripHeight(count: count))
        let content = SidebarView(frame: NSRect(origin: .zero, size: size))
        content.setOpen(open, animated: false)
        content.setCount(titles.count, of: 4)
        content.setDots(titles.map { ($0.phase, $0.isOpen) })
        var keep: [AnyObject] = []
        for (i, t) in titles.enumerated() {
            let token = NSObject()
            keep.append(token)
            let row = RowView(id: ObjectIdentifier(token))
            row.apply(Row(id: ObjectIdentifier(token), title: t.title, subtitle: t.subtitle, phase: t.phase, isOpen: t.isOpen))
            row.frame = NSRect(x: rowInset, y: headerHeight + CGFloat(i) * rowPitch, width: width - rowInset * 2, height: rowHeight)
            row.isHidden = !open
            content.addSubview(row)
        }
        content.layoutSubtreeIfNeeded()
        content.appearance = NSAppearance.currentDrawing()
        guard let rep = content.snapshotRep() else { return nil }
        _ = keep
        return rep.cgImage
    }
}

// MARK: - Window content

/// The black card: header with a fold button, or (folded) a strip with a dot per agent.
private final class SidebarView: FirstMouseView {
    var onToggle: (() -> Void)?

    static let dotSize: CGFloat = 8
    private static let dotPitch: CGFloat = 18
    /// The folded pill: the mark sits in the top cap, the chats' dots below it, and the bottom cap mirrors the top.
    static let markTop: CGFloat = 11
    static let markSize: CGFloat = 14
    private static let dotsTop: CGFloat = markTop + markSize + 9

    static func stripHeight(count: Int) -> CGFloat { dotsTop + CGFloat(max(count, 1)) * dotPitch + 12 }
    static func dotCenterY(_ index: Int) -> CGFloat { dotsTop + CGFloat(index) * dotPitch + dotPitch / 2 }

    private let header = NSView()
    private let strip = StripView()
    private let titleField = NSTextField(labelWithString: "Chats")
    private let foldButton = IconButton(symbol: "sidebar.right", help: "Fold the sidebar")
    private var open = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = Theme.canvas.dark.withAlphaComponent(0.96).cgColor
        layer?.cornerRadius = Theme.Radius.container
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = Theme.hairline.dark.cgColor

        // The header sits on the rows' grid: the spark over the circles, "Chats" over the titles, the fold button over the ×.
        header.frame = NSRect(x: 0, y: 0, width: AgentSidebar.width, height: AgentSidebar.headerHeight)
        header.autoresizingMask = [.width]
        let spark = NSImageView(image: ClaudeMark.menuBarImage())
        spark.contentTintColor = Theme.inkTertiary.dark
        let sparkX = AgentSidebar.rowInset + AgentSidebar.discX
        spark.frame = NSRect(x: sparkX - 7, y: 14, width: 14, height: 14)
        titleField.font = .merlin(12, .semibold)
        titleField.textColor = Theme.inkSecondary.dark
        titleField.frame = NSRect(x: AgentSidebar.rowInset + AgentSidebar.textX, y: 12, width: 80, height: 17)
        foldButton.frame = NSRect(x: AgentSidebar.width - AgentSidebar.rowInset - 30, y: 9, width: 24, height: 24)
        foldButton.autoresizingMask = [.minXMargin]
        foldButton.onClick = { [weak self] in self?.onToggle?() }
        for v in [spark, titleField, foldButton] { header.addSubview(v) }
        addSubview(header)

        strip.frame = bounds
        strip.autoresizingMask = [.width, .height]
        strip.onClick = { [weak self] in self?.onToggle?() }
        strip.isHidden = true
        strip.alphaValue = 0
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ n: Int, of max: Int) {
        // No counter in the header; the number lives in the tooltip.
        titleField.toolTip = "\(n) of \(max) chats"
    }
    func setDots(_ dots: [(AgentPhase, Bool)]) { strip.setDots(dots) }

    func setOpen(_ isOpen: Bool, animated: Bool) {
        open = isOpen
        // Open it's a card; folded it's a capsule (fully round ends).
        layer?.cornerRadius = isOpen ? Theme.Radius.container : AgentSidebar.stripWidth / 2
        header.isHidden = false
        strip.isHidden = false
        let finish = { [weak self] in
            guard let self else { return }
            self.header.isHidden = !self.open
            self.strip.isHidden = self.open
        }
        guard animated else {
            header.alphaValue = isOpen ? 1 : 0
            strip.alphaValue = isOpen ? 0 : 1
            return finish()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            header.animator().alphaValue = isOpen ? 1 : 0
            strip.animator().alphaValue = isOpen ? 0 : 1
        }, completionHandler: finish)
    }

    // Rows sit above the header and strip; a click on the empty card does nothing.
}

/// The folded sidebar: a slim capsule with the Chats spark on top (an unfold arrow while the pointer is over it) and one
/// dot per chat that says what it's doing: a hollow ring waiting for you, a softly breathing accent dot working, a solid
/// ink dot done, alert red when something went wrong.
private final class StripView: FirstMouseView {
    var onClick: (() -> Void)?
    private var dots: [CAShapeLayer] = []
    private let mark = NSImageView()
    private let arrow = NSImageView()
    private let hoverFill = CALayer()
    private var hovering = false { didSet { if hovering != oldValue { showHover() } } }

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        hoverFill.backgroundColor = Theme.ink.dark.withAlphaComponent(0.06).cgColor
        hoverFill.opacity = 0
        layer?.addSublayer(hoverFill)
        let cell = NSRect(x: (AgentSidebar.stripWidth - SidebarView.markSize) / 2, y: SidebarView.markTop,
                          width: SidebarView.markSize, height: SidebarView.markSize)
        mark.image = ClaudeMark.menuBarImage()
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.contentTintColor = Theme.inkSecondary.dark
        mark.frame = cell
        mark.setAccessibilityElement(false)
        addSubview(mark)
        arrow.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Unfold the sidebar")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        arrow.contentTintColor = Theme.ink.dark
        arrow.frame = cell
        arrow.alphaValue = 0
        addSubview(arrow)
        toolTip = "Unfold the chat sidebar"
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Unfold the chat sidebar")
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverFill.frame = bounds
        hoverFill.cornerRadius = bounds.width / 2
        CATransaction.commit()
    }

    /// Under the pointer the spark gives way to the unfold arrow and the capsule lifts a touch: it reads as a button.
    private func showHover() {
        let instant = Motion.still
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = instant ? 0 : 0.15
            ctx.timingFunction = Motion.easeOut
            mark.animator().alphaValue = hovering ? 0 : 1
            arrow.animator().alphaValue = hovering ? 1 : 0
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(instant ? 0 : 0.15)
        hoverFill.opacity = hovering ? 1 : 0
        CATransaction.commit()
    }

    func setDots(_ states: [(AgentPhase, Bool)]) {
        while dots.count < states.count {
            let dot = CAShapeLayer()
            layer?.addSublayer(dot)
            dots.append(dot)
        }
        while dots.count > states.count { dots.removeLast().removeFromSuperlayer() }
        let d = SidebarView.dotSize
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, (phase, _)) in states.enumerated() {
            let dot = dots[i]
            dot.frame = CGRect(x: (AgentSidebar.stripWidth - d) / 2, y: SidebarView.dotCenterY(i) - d / 2, width: d, height: d)
            switch phase {
            case .idle: // waiting for your question: an empty ring
                dot.path = CGPath(ellipseIn: CGRect(x: 0.75, y: 0.75, width: d - 1.5, height: d - 1.5), transform: nil)
                dot.fillColor = nil
                dot.strokeColor = Theme.inkSecondary.dark.cgColor
                dot.lineWidth = 1.5
            default:
                dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: d, height: d)), transform: nil)
                dot.fillColor = AgentBubble.color(for: phase).cgColor
                dot.strokeColor = nil
                dot.lineWidth = 0
            }
            // Only a working chat breathes, slowly; with Reduce Motion it holds still.
            if phase == .working && !Motion.reduceMotion && !Motion.still {
                if dot.animation(forKey: "pulse") == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 0.4
                    pulse.toValue = 1
                    pulse.duration = 1.1
                    pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    pulse.autoreverses = true
                    pulse.repeatCount = .infinity
                    dot.add(pulse, forKey: "pulse")
                }
            } else {
                dot.removeAnimation(forKey: "pulse")
            }
        }
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    // A click unfolds the sidebar and hides the strip under the pointer, so no exit arrives: forget the hover here.
    override func viewDidHide() { super.viewDidHide(); hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
}

/// A small round icon button (used for the fold control).
private final class IconButton: FirstMouseView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var hovering = false {
        didSet {
            layer?.backgroundColor = (hovering ? Theme.surfaceRaised.dark : NSColor.clear).cgColor
            icon.contentTintColor = hovering ? Theme.ink.dark : Theme.inkTertiary.dark
        }
    }

    init(symbol: String, help: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        wantsLayer = true
        layer?.cornerRadius = Theme.Radius.chip
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .regular))
        icon.contentTintColor = Theme.inkTertiary.dark
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        toolTip = help
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
}

// MARK: - Row

/// One chat in the sidebar: circle, title, status line, and a × (on hover) that deletes the chat.
private final class RowView: FirstMouseView {
    let id: ObjectIdentifier
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?
    var onStar: ((ObjectIdentifier) -> Void)?

    let discView = DiscView(diameter: AgentSidebar.disc, pad: 8)
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let cross = NSImageView()
    private let star = NSImageView()
    private var starred = false
    private var canStar = false
    private let highlight = CALayer()
    /// The slim ink bar on the open row's left edge (the Library marks its selected rows the same way).
    private let selectionBar = CALayer()
    private var isOpenRow = false
    private var hovering = false { didSet { refresh() } }

    override var isFlipped: Bool { true }

    init(id: ObjectIdentifier) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: AgentSidebar.width - AgentSidebar.rowInset * 2, height: AgentSidebar.rowHeight))
        wantsLayer = true
        highlight.cornerRadius = Theme.Radius.control
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)
        selectionBar.backgroundColor = Theme.ink.dark.cgColor
        selectionBar.cornerRadius = 1
        selectionBar.opacity = 0
        layer?.addSublayer(selectionBar)

        let c = NSPoint(x: AgentSidebar.discX, y: AgentSidebar.rowHeight / 2)
        let disc = discView.bounds.width
        discView.frame = NSRect(x: c.x - disc / 2, y: c.y - disc / 2, width: disc, height: disc)
        addSubview(discView)

        titleField.font = .merlin(13, .medium)
        titleField.textColor = Theme.ink.dark
        subtitleField.font = .merlin(12)
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        layoutText()

        cross.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete chat")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [Theme.canvas.dark, Theme.inkSecondary.dark])))
        cross.frame = crossRect
        cross.isHidden = true
        addSubview(cross)
        star.frame = starRect
        star.isHidden = true
        addSubview(star)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }


    private var starRect: NSRect { NSRect(x: bounds.width - 50, y: (bounds.height - 20) / 2, width: 20, height: 20) }
    private var crossRect: NSRect { NSRect(x: bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        selectionBar.frame = CGRect(x: 0, y: 14, width: 2, height: max(0, bounds.height - 28))
        CATransaction.commit()
        layoutText()
    }

    /// The text runs to the row's right edge; it only steps back for the star and × while they're showing (so a resting
    /// row shows its whole status, "Done · click to read", not "Done · click to…").
    private func layoutText() {
        let x = AgentSidebar.textX
        let end: CGFloat = !star.isHidden ? starRect.minX - 4 : (!cross.isHidden ? crossRect.minX - 4 : bounds.width - 12)
        let width = max(0, end - x)
        let top = (bounds.height - 34) / 2
        titleField.frame = NSRect(x: x, y: top, width: width, height: 17)
        subtitleField.frame = NSRect(x: x, y: top + 18, width: width, height: 16)
    }

    func apply(_ row: AgentSidebar.Row) {
        titleField.stringValue = row.title
        toolTip = row.title
        subtitleField.stringValue = row.subtitle
        subtitleField.textColor = Self.statusColor(row.phase)
        isOpenRow = row.isOpen
        starred = row.starred
        canStar = row.canStar
        discView.setPhase(row.phase)
        refresh()
    }

    private static func statusColor(_ phase: AgentPhase) -> NSColor {
        switch phase {
        case .idle: return Theme.inkTertiary.dark
        case .working: return Theme.inkSecondary.dark
        case .done: return Theme.inkSecondary.dark // done reads in the circle; the words stay quiet
        case .failed: return AgentBubble.failed
        }
    }

    private func refresh() {
        cross.isHidden = !hovering
        star.image = NSImage(systemSymbolName: starred ? "star.fill" : "star", accessibilityDescription: starred ? "Unstar" : "Star")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [starred ? Theme.ink.dark : Theme.inkSecondary.dark])))
        star.isHidden = !canStar || !(hovering || starred) // a starred chat always shows its star: one star, click to unstar
        highlight.backgroundColor = (isOpenRow ? Theme.surfaceSelected.dark : (hovering ? Theme.surfaceRaised.dark : NSColor.clear)).cgColor
        selectionBar.opacity = isOpenRow ? 1 : 0
        layoutText()
    }

    /// Fades in and settles from 96% (critically damped, no overshoot) when a chat is added or the sidebar unfolds.
    /// Reduce Motion: just a short fade. Headless pictures: no motion.
    func arrive() {
        if Motion.still { alphaValue = 1; return }
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Motion.reduceMotion ? 0.15 : 0.22
            ctx.timingFunction = Motion.easeOut
            animator().alphaValue = 1
        }
        Motion.popIn(self, from: 0.96, response: 0.2, damping: 1)
    }

    /// Fades out (faster than it came in), then drops out of the sidebar.
    func leave() {
        if Motion.still { removeFromSuperview(); return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            ctx.timingFunction = Motion.easeOut
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    /// A chat just landed here: the row lights up for a moment and the circle settles in (no bounce).
    func flash() {
        guard !Motion.still else { return }
        let glow = CABasicAnimation(keyPath: "backgroundColor")
        glow.fromValue = Theme.ink.dark.withAlphaComponent(0.12).cgColor
        glow.toValue = highlight.backgroundColor
        glow.duration = 0.3
        glow.timingFunction = Motion.easeOut
        highlight.add(glow, forKey: "flash")
        Motion.popIn(discView, from: 0.95, response: 0.2, damping: 1)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if !star.isHidden, starRect.insetBy(dx: -4, dy: -6).contains(p) {
            onStar?(id)
        } else if !cross.isHidden, crossRect.insetBy(dx: -6, dy: -6).contains(p) {
            onDelete?(id)
        } else {
            onSelect?(id)
        }
    }
}

// MARK: - The sidebar's window

/// The sidebar's window: a press on its handle drags it. A press that never moves is still a click (the fold button,
/// the folded strip), and a drag never counts as one. Double-clicking the handle puts it back in the corner.
final class SidebarPanel: FloatingPanel {
    /// Whether a press at this point (window coordinates) may start a drag.
    var dragZone: ((NSPoint) -> Bool)?
    var onDragEnded: (() -> Void)?
    var onReset: (() -> Void)?
    private var pressed = false
    private var dragging = false
    private var mouseStart = NSPoint.zero
    private var originStart = NSPoint.zero

    init(size: NSSize) { super.init(size: size, canKey: false) }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown where dragZone?(event.locationInWindow) == true:
            if event.clickCount == 2, frame.height - event.locationInWindow.y < AgentSidebar.headerHeightForDrag { onReset?(); return }
            pressed = true
            dragging = false
            mouseStart = convertPoint(toScreen: event.locationInWindow)
            originStart = frame.origin
            super.sendEvent(event)
        case .leftMouseDragged where pressed:
            let now = convertPoint(toScreen: event.locationInWindow)
            let dx = now.x - mouseStart.x, dy = now.y - mouseStart.y
            if !dragging {
                guard hypot(dx, dy) >= 4 else { return } // still a click
                dragging = true
            }
            setFrameOrigin(NSPoint(x: originStart.x + dx, y: originStart.y + dy))
        case .leftMouseUp where pressed:
            pressed = false
            if dragging {
                dragging = false
                onDragEnded?()
                return // the press became a drag: it isn't also a click
            }
            super.sendEvent(event)
        default:
            super.sendEvent(event)
        }
    }
}
