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
        /// A background task rather than a chat.
        var isTask = false
    }

    var onSelect: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?

    // Geometry (points).
    static let width: CGFloat = 244
    static let stripWidth: CGFloat = 30
    static let margin: CGFloat = 10
    fileprivate static let headerHeight: CGFloat = 40
    fileprivate static let rowHeight: CGFloat = 52
    fileprivate static let rowPitch: CGFloat = 56
    fileprivate static let rowInset: CGFloat = 8
    fileprivate static let bottomPad: CGFloat = 10
    fileprivate static let disc: CGFloat = 34
    /// Where the circle's center sits inside a row.
    fileprivate static let discX: CGFloat = 26

    private let panel: FloatingPanel
    private let content = SidebarView(frame: NSRect(x: 0, y: 0, width: AgentSidebar.width, height: 100))
    private var rows: [Row] = []
    private var views: [ObjectIdentifier: RowView] = [:]
    private(set) var isOpen: Bool

    init(open: Bool = Settings.shared.sidebarOpen) {
        isOpen = open
        panel = FloatingPanel(size: NSSize(width: Self.width, height: 100), canKey: false)
        panel.contentView = content
        content.onToggle = { [weak self] in self?.toggle() }
        content.setOpen(open, animated: false)
    }

    var frame: NSRect { panel.frame }
    var isShown: Bool { panel.isVisible && panel.alphaValue > 0.01 }

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
        let chats = newRows.filter { !$0.isTask }.count
        content.setCount(chats, of: Settings.shared.maxAgents, tasks: newRows.count - chats)
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

    /// Where the sidebar is (or is moving to): the top-right corner of the laptop screen.
    private func targetFrame() -> NSRect {
        let vf = Self.dockScreen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let s = size(open: isOpen, count: max(rows.count, 1))
        return NSRect(x: vf.maxX - Self.margin - s.width, y: vf.maxY - Self.margin - s.height,
                      width: s.width, height: s.height)
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
            return (screenCenter(view.discView), screenCenter(view.auraView), NSPoint(x: want.midX, y: want.midY))
        }
    }
    var debugPanelFrame: NSRect { panel.frame }
    var debugIsVisible: Bool { panel.isVisible }
    func debugTitles() -> [String] { rows.map(\.title) }
    func debugSubtitles() -> [String] { rows.compactMap { views[$0.id]?.debugSubtitle } }
    func debugFlashAll() { views.keys.forEach(flash) }
    var debugRowCount: Int { rows.count }
    func debugClickRow(_ index: Int) { if rows.indices.contains(index) { onSelect?(rows[index].id) } }
    func debugClickDelete(_ index: Int) { if rows.indices.contains(index) { onDelete?(rows[index].id) } }

    /// The sidebar as it looks right now, over a backdrop (the windows' blur and shadow can't be captured).
    func debugSnapshot(backdrop: NSColor = NSColor(white: 0.30, alpha: 1)) -> NSBitmapImageRep? {
        let pad: CGFloat = 16
        let size = NSSize(width: panel.frame.width + pad * 2, height: panel.frame.height + pad * 2)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
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

// MARK: - Window content

/// The black card: header with a fold button, or (folded) a strip with a dot per agent.
private final class SidebarView: NSView {
    var onToggle: (() -> Void)?

    static let dotSize: CGFloat = 10
    private static let dotPitch: CGFloat = 18

    static func stripHeight(count: Int) -> CGFloat { 40 + CGFloat(max(count, 1)) * dotPitch + 6 }
    static func dotCenterY(_ index: Int) -> CGFloat { 40 + CGFloat(index) * dotPitch + dotPitch / 2 }

    private let header = NSView()
    private let strip = StripView()
    private let titleField = NSTextField(labelWithString: "Chats")
    private let countField = NSTextField(labelWithString: "")
    private let foldButton = IconButton(symbol: "sidebar.right", help: "Fold the sidebar")
    private var open = true

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 0.045, alpha: 0.96).cgColor
        layer?.cornerRadius = 18
        layer?.cornerCurve = .continuous
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(white: 1, alpha: 0.09).cgColor

        header.frame = NSRect(x: 0, y: 0, width: AgentSidebar.width, height: AgentSidebar.headerHeight)
        header.autoresizingMask = [.width]
        let spark = NSImageView(image: ClaudeMark.menuBarImage())
        spark.contentTintColor = NSColor(white: 1, alpha: 0.72)
        spark.frame = NSRect(x: 16, y: 13, width: 14, height: 14)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = NSColor(white: 1, alpha: 0.72)
        titleField.frame = NSRect(x: 36, y: 11, width: 80, height: 17)
        countField.font = .systemFont(ofSize: 11)
        countField.textColor = NSColor(white: 1, alpha: 0.38)
        countField.alignment = .right
        countField.frame = NSRect(x: AgentSidebar.width - 148, y: 12, width: 104, height: 15)
        countField.autoresizingMask = [.minXMargin]
        foldButton.frame = NSRect(x: AgentSidebar.width - 36, y: 8, width: 24, height: 24)
        foldButton.autoresizingMask = [.minXMargin]
        foldButton.onClick = { [weak self] in self?.onToggle?() }
        for v in [spark, titleField, countField, foldButton] { header.addSubview(v) }
        addSubview(header)

        strip.frame = bounds
        strip.autoresizingMask = [.width, .height]
        strip.onClick = { [weak self] in self?.onToggle?() }
        strip.isHidden = true
        strip.alphaValue = 0
        addSubview(strip)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setCount(_ n: Int, of max: Int, tasks: Int = 0) {
        countField.stringValue = "\(n) of \(max)" + (tasks > 0 ? " · \(tasks) task\(tasks == 1 ? "" : "s")" : "")
    }
    func setDots(_ dots: [(AgentPhase, Bool)]) { strip.setDots(dots) }

    func setOpen(_ isOpen: Bool, animated: Bool) {
        open = isOpen
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
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The folded sidebar: an unfold arrow and one small dot per agent, colored by what it's doing.
private final class StripView: NSView {
    var onClick: (() -> Void)?
    private var dots: [CAShapeLayer] = []
    private let arrow = NSImageView()

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .bold)
        arrow.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Unfold the sidebar")?
            .withSymbolConfiguration(config)
        arrow.contentTintColor = NSColor(white: 1, alpha: 0.6)
        arrow.frame = NSRect(x: 0, y: 10, width: AgentSidebar.stripWidth, height: 18)
        addSubview(arrow)
        toolTip = "Unfold the chat sidebar"
    }

    required init?(coder: NSCoder) { fatalError() }

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
            dot.path = CGPath(ellipseIn: CGRect(origin: .zero, size: CGSize(width: d, height: d)), transform: nil)
            let color = AgentBubble.color(for: phase)
            dot.fillColor = color.cgColor
            dot.shadowColor = color.cgColor
            dot.shadowOpacity = 0.9
            dot.shadowRadius = 4
            dot.shadowOffset = .zero
            if phase == .working || phase == .idle {
                if dot.animation(forKey: "pulse") == nil {
                    let pulse = CABasicAnimation(keyPath: "opacity")
                    pulse.fromValue = 0.45
                    pulse.toValue = 1
                    pulse.duration = 0.8
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

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { onClick?() }
}

/// A small round icon button (used for the fold control).
private final class IconButton: NSView {
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private var hovering = false { didSet { layer?.backgroundColor = NSColor(white: 1, alpha: hovering ? 0.14 : 0).cgColor } }

    init(symbol: String, help: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        wantsLayer = true
        layer?.cornerRadius = 12
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .semibold))
        icon.contentTintColor = NSColor(white: 1, alpha: 0.7)
        icon.frame = bounds
        icon.autoresizingMask = [.width, .height]
        addSubview(icon)
        toolTip = help
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
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
private final class RowView: NSView {
    let id: ObjectIdentifier
    var onSelect: ((ObjectIdentifier) -> Void)?
    var onDelete: ((ObjectIdentifier) -> Void)?

    let discView = DiscView(diameter: AgentSidebar.disc, pad: 10)
    let auraView = GlowView(diameter: AgentSidebar.disc, reach: 12)
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let cross = NSImageView()
    private let highlight = CALayer()
    private var isOpenRow = false
    private var hovering = false { didSet { refresh() } }

    override var isFlipped: Bool { true }

    init(id: ObjectIdentifier) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: AgentSidebar.width - AgentSidebar.rowInset * 2, height: AgentSidebar.rowHeight))
        wantsLayer = true
        highlight.cornerRadius = 12
        highlight.cornerCurve = .continuous
        layer?.addSublayer(highlight)

        let c = NSPoint(x: AgentSidebar.discX, y: AgentSidebar.rowHeight / 2)
        let aura = auraView.bounds.width
        auraView.frame = NSRect(x: c.x - aura / 2, y: c.y - aura / 2, width: aura, height: aura)
        let disc = discView.bounds.width
        discView.frame = NSRect(x: c.x - disc / 2, y: c.y - disc / 2, width: disc, height: disc)
        addSubview(auraView)
        addSubview(discView)

        let textX: CGFloat = 52
        let textWidth = bounds.width - textX - 30
        titleField.font = .systemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = NSColor(white: 1, alpha: 0.94)
        subtitleField.font = .systemFont(ofSize: 11)
        for field in [titleField, subtitleField] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            addSubview(field)
        }
        titleField.frame = NSRect(x: textX, y: 9, width: textWidth, height: 17)
        subtitleField.frame = NSRect(x: textX, y: 27, width: textWidth, height: 15)

        cross.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Delete chat")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
                .applying(.init(paletteColors: [NSColor(white: 0.1, alpha: 1), NSColor(white: 1, alpha: 0.62)])))
        cross.frame = crossRect
        cross.isHidden = true
        addSubview(cross)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError() }

    var debugSubtitle: String { subtitleField.stringValue }

    private var crossRect: NSRect { NSRect(x: bounds.width - 28, y: (bounds.height - 20) / 2, width: 20, height: 20) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        highlight.frame = bounds
        CATransaction.commit()
    }

    func apply(_ row: AgentSidebar.Row) {
        titleField.stringValue = row.title
        toolTip = row.title
        subtitleField.stringValue = row.subtitle
        subtitleField.textColor = Self.statusColor(row.phase)
        isOpenRow = row.isOpen
        discView.setPhase(row.phase)
        auraView.setPhase(row.phase)
        refresh()
    }

    private static func statusColor(_ phase: AgentPhase) -> NSColor {
        switch phase {
        case .idle: return NSColor(white: 1, alpha: 0.45)
        case .working: return AgentBubble.lightPurple.withAlphaComponent(0.9)
        case .done: return NSColor(srgbRed: 0.42, green: 0.84, blue: 0.58, alpha: 1)
        case .failed: return NSColor(srgbRed: 1.0, green: 0.52, blue: 0.5, alpha: 1)
        }
    }

    private func refresh() {
        cross.isHidden = !hovering
        let alpha: CGFloat = isOpenRow ? 0.15 : (hovering ? 0.09 : 0)
        highlight.backgroundColor = NSColor(white: 1, alpha: alpha).cgColor
    }

    /// Slides in when a chat is added (or the sidebar unfolds).
    func arrive() {
        alphaValue = 0
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            animator().alphaValue = 1
        }
        Motion.popIn(discView, from: 0.6, damping: 12, stiffness: 240)
        discView.celebrate()
    }

    /// Fades out, then drops out of the sidebar.
    func leave() {
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.16
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.removeFromSuperview() })
    }

    /// A chat just landed here: the row lights up for a moment and the circle bounces.
    func flash() {
        let glow = CABasicAnimation(keyPath: "backgroundColor")
        glow.fromValue = NSColor(white: 1, alpha: 0.32).cgColor
        glow.toValue = highlight.backgroundColor
        glow.duration = 0.6
        highlight.add(glow, forKey: "flash")
        Motion.popIn(discView, from: 0.8, damping: 10, stiffness: 300)
        discView.celebrate()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { isHidden ? nil : (frame.contains(point) ? self : nil) }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return }
        if !cross.isHidden, crossRect.insetBy(dx: -6, dy: -6).contains(p) {
            onDelete?(id)
        } else {
            onSelect?(id)
        }
    }
}
