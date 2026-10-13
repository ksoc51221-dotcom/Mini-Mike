import AppKit
import SwiftUI

/// The background agents' own home, separate from the chat sidebar. Minimized, it's a small black strip on the
/// right edge of the screen (half-way down) with a little cat for each agent. Expanded, it's a black bar at the top
/// centre of the screen where each agent is a bigger cat: click one for its card, + for a new job.
/// ⌘⇧A, clicking the strip, or asking by voice expands it; clicking elsewhere, Esc, ⌘⇧A or its − button
/// minimizes it back to the strip. The agents keep working either way.
final class AgentBar {
    static let shared = AgentBar()

    enum Layout {
        static let height: CGFloat = 70
        static let pad: CGFloat = 8
        static let slotWidth: CGFloat = 226
        static let gap: CGFloat = 4
        static let catArea: CGFloat = 80
        static let newJobWidth: CGFloat = 48
        static let minimizeWidth: CGFloat = 34
        static let emptyWidth: CGFloat = 300
        /// Space between the menu bar and the agent bar.
        static let topGap: CGFloat = 6
        static let corner: CGFloat = 18

        // The Allow / Deny buttons on an agent that's waiting for you: where they sit inside its slot (window points,
        // origin bottom-left). Drawing and clicking both use these, so they can't disagree.
        static let allowSize = CGSize(width: 64, height: 22)
        static let denySize = CGSize(width: 52, height: 22)
        static let buttonGap: CGFloat = 6
        /// The text column starts after the cat (and the 2 points between them).
        static let textLeading: CGFloat = catArea + 2
        static let buttonsBottom: CGFloat = 8
        static func allowRect(inSlot slot: NSRect) -> NSRect {
            NSRect(x: slot.minX + textLeading, y: slot.minY + buttonsBottom, width: allowSize.width, height: allowSize.height)
        }
        static func denyRect(inSlot slot: NSRect) -> NSRect {
            NSRect(x: slot.minX + textLeading + allowSize.width + buttonGap, y: slot.minY + buttonsBottom,
                   width: denySize.width, height: denySize.height)
        }

        // The minimized strip.
        static let stripWidth: CGFloat = 50
        static let stripCell: CGFloat = 32
        static let stripPad: CGFloat = 8
        static let stripMaxCats = 6
        static let stripCorner: CGFloat = 14
        /// Gap between the strip and the screen's right edge.
        static let stripInset: CGFloat = 4
    }

    /// What a click on the bar landed on.
    enum Hit: Equatable { case slot(Int), close(Int), allow(Int), deny(Int), newJob, minimize }

    let model = AgentBarModel()
    let card = TaskCardController()
    private var panel: AgentBarPanel?
    private var host: NSHostingView<AgentBarView>?
    private var strip: AgentBarPanel?
    private var stripHost: NSHostingView<AgentStripView>?
    private var clickMonitor: Any?
    private var keyMonitor: Any?
    private var ghost: Ghost?
    /// Expanded (the bar at the top) or minimized (the strip at the side).
    private(set) var expanded = false
    /// Where the bar is going (it may still be flying in): cards and the job box hang under this.
    private var settledFrame = NSRect.zero

    var isShowing: Bool { expanded }

    private init() {
        TaskEngine.shared.onChange = { [weak self] in self?.sync() }
        TaskEngine.shared.onAttention = { [weak self] task in self?.attention(task) }
        card.onHide = { [weak self] in self?.model.openID = nil }
    }

    /// Puts the minimized strip on screen (at launch).
    func start() {
        if panel == nil { build() }
        sync()
        placeStrip()
        strip?.alphaValue = 1
        strip?.orderFrontRegardless()
        model.stripVisible = true
    }

    // MARK: Expanding and minimizing

    /// ⌘⇧A. With no agents yet, it opens straight to the new-job box.
    func toggle() {
        if expanded { hide() } else { show(newJob: TaskEngine.shared.tasks.isEmpty) }
    }

    /// Expands to the bar at the top. `newJob` also opens the + box (with `prefill`/`message`, e.g. from voice).
    /// Otherwise, if an agent is waiting for your OK, its card opens.
    func show(newJob: Bool = false, prefill: String = "", message: String? = nil) {
        if panel == nil { build() }
        guard let panel, let host else { return }
        sync()
        let target = frame(width: width(for: model.tasks.count), on: screenUnderMouse())
        settledFrame = target
        let wasExpanded = expanded
        expanded = true
        watchForClicksElsewhere()
        let then = { [weak self] in
            guard let self, self.expanded else { return }
            if newJob { self.openNewJob(prefill: prefill, message: message) } else { self.openWaitingCard() }
        }
        if wasExpanded && panel.isVisible && panel.alphaValue > 0.5 {
            if panel.frame != target { panel.setFrame(target, display: true) }
            return then()
        }
        ghost?.dismiss()
        panel.setFrame(target, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        model.visible = true
        host.layoutSubtreeIfNeeded()
        // Fly from the strip to the top: a picture of the strip turns into a picture of the bar on the way.
        if let strip, strip.isVisible, strip.alphaValue > 0.1, let from = snapshot(stripHost), let to = snapshot(host) {
            let start = strip.frame
            strip.alphaValue = 0
            model.stripVisible = false
            let g = Ghost(image: from, frame: start, radius: Layout.stripCorner, gravity: .resize, area: flightArea(start, target))
            ghost = g
            g.animate(to: target, radius: Layout.corner, crossfadeTo: to, gravity: .resize, duration: 0.34,
                      timing: CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)) { [weak self] remove in
                guard let self else { return remove() }
                if self.expanded {
                    panel.alphaValue = 1
                    self.strip?.orderOut(nil)
                }
                remove()
                if self.ghost === g { self.ghost = nil }
                then()
            }
        } else {
            strip?.orderOut(nil)
            model.stripVisible = false
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                panel.animator().alphaValue = 1
            }, completionHandler: then)
        }
    }

    /// Back to the strip on the right edge.
    func hide() {
        removeMonitors()
        card.hide()
        TaskBox.shared.hide()
        guard expanded, let panel else { return }
        expanded = false
        ghost?.dismiss()
        placeStrip()
        guard let strip else { return }
        strip.alphaValue = 0
        strip.orderFrontRegardless()
        model.stripVisible = true
        stripHost?.layoutSubtreeIfNeeded()
        let start = panel.frame
        if panel.isVisible, let from = snapshot(host), let to = snapshot(stripHost) {
            panel.alphaValue = 0
            panel.orderOut(nil)
            model.visible = false
            let g = Ghost(image: from, frame: start, radius: Layout.corner, gravity: .resize, area: flightArea(start, strip.frame))
            ghost = g
            g.animate(to: strip.frame, radius: Layout.stripCorner, crossfadeTo: to, gravity: .resize, duration: 0.3,
                      timing: CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)) { [weak self] remove in
                guard let self else { return remove() }
                if !self.expanded { strip.alphaValue = 1 }
                remove()
                if self.ghost === g { self.ghost = nil }
            }
        } else {
            panel.orderOut(nil)
            model.visible = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                strip.animator().alphaValue = 1
            }
        }
    }

    /// A task needs your OK, or finished: expand with its card open.
    private func attention(_ task: BackgroundTask) {
        if expanded {
            if let i = model.tasks.firstIndex(where: { $0.id == task.id }) { openCard(i) }
            return
        }
        show()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.expanded, let i = self.model.tasks.firstIndex(where: { $0.id == task.id }) else { return }
            self.openCard(i)
        }
    }

    /// The first agent waiting for your OK gets its card opened (so the Allow button is right there).
    private func openWaitingCard() {
        guard !card.isShowing, let i = model.tasks.firstIndex(where: { $0.state == .needsApproval }) else { return }
        openCard(i)
    }

    // MARK: Clicks

    func handle(_ hit: Hit) {
        switch hit {
        case .slot(let i):
            guard model.tasks.indices.contains(i) else { return }
            if model.openID == model.tasks[i].id && card.isShowing { card.hide() } else { openCard(i) }
        case .close(let i):
            guard model.tasks.indices.contains(i) else { return }
            let task = model.tasks[i]
            if card.task === task { card.hide() }
            TaskEngine.shared.dismiss(task)
        case .allow(let i):
            guard model.tasks.indices.contains(i) else { return }
            let task = model.tasks[i]
            // A plan can be approved right here; a choice (which chapters, and what it'll cost) is made on the card.
            if task.canQuickApprove {
                if card.task === task { card.hide() }
                TaskEngine.shared.approve(task)
            } else {
                openCard(i)
            }
        case .deny(let i):
            guard model.tasks.indices.contains(i) else { return }
            let task = model.tasks[i]
            if card.task === task { card.hide() }
            TaskEngine.shared.deny(task)
        case .newJob:
            openNewJob()
        case .minimize:
            hide()
        }
    }

    /// A click anywhere on the strip expands the bar.
    func stripClicked() { show() }

    private func openCard(_ i: Int) {
        guard model.tasks.indices.contains(i), panel != nil else { return }
        TaskBox.shared.hide()
        let task = model.tasks[i]
        let slot = slotRect(i)
        let onScreen = NSRect(x: settledFrame.minX + slot.minX, y: settledFrame.minY, width: slot.width, height: settledFrame.height)
        card.show(task, anchor: .below(onScreen))
        model.openID = task.id
    }

    private func openNewJob(prefill: String = "", message: String? = nil) {
        card.hide()
        guard panel != nil else { return }
        TaskBox.shared.show(prefill: prefill, message: message, below: settledFrame)
    }

    /// Where things are inside the bar, in window points (origin bottom-left).
    func slotRect(_ i: Int) -> NSRect {
        NSRect(x: Layout.pad + CGFloat(i) * (Layout.slotWidth + Layout.gap), y: 0, width: Layout.slotWidth, height: Layout.height)
    }

    func hit(at p: NSPoint) -> Hit? {
        let w = width(for: model.tasks.count)
        if p.x >= w - Layout.pad - Layout.minimizeWidth { return .minimize }
        if p.x >= w - Layout.pad - Layout.minimizeWidth - Layout.newJobWidth { return .newJob }
        for i in model.tasks.indices {
            let r = slotRect(i)
            guard r.contains(p) else { continue }
            if model.tasks[i].state == .needsApproval {
                // Generous click targets: the button plus a little around it.
                if Layout.allowRect(inSlot: r).insetBy(dx: -3, dy: -4).contains(p) { return .allow(i) }
                if Layout.denyRect(inSlot: r).insetBy(dx: -3, dy: -4).contains(p) { return .deny(i) }
            }
            if model.closable(i), NSRect(x: r.maxX - 24, y: r.maxY - 24, width: 24, height: 24).contains(p) { return .close(i) }
            return .slot(i)
        }
        return nil
    }

    // MARK: Layout

    private func width(for count: Int) -> CGFloat {
        let slots = count == 0 ? Layout.emptyWidth : CGFloat(count) * Layout.slotWidth + CGFloat(count - 1) * Layout.gap
        return Layout.pad * 2 + slots + Layout.gap + Layout.newJobWidth + Layout.minimizeWidth
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    }

    private func frame(width: CGFloat, on screen: NSScreen?) -> NSRect {
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = min(width, vf.width - 16)
        return NSRect(x: vf.midX - w / 2, y: vf.maxY - Layout.topGap - Layout.height, width: w, height: Layout.height)
    }

    /// The strip hugs the right edge of the main screen, half-way down.
    func stripFrame() -> NSRect {
        let vf = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let cats = max(1, min(model.tasks.count, Layout.stripMaxCats)) + (model.tasks.count > Layout.stripMaxCats ? 1 : 0)
        let h = Layout.stripPad * 2 + CGFloat(cats) * Layout.stripCell
        return NSRect(x: vf.maxX - Layout.stripWidth - Layout.stripInset, y: (vf.midY - h / 2).rounded(), width: Layout.stripWidth, height: h)
    }

    private func placeStrip() {
        guard let strip else { return }
        let f = stripFrame()
        if strip.frame != f { strip.setFrame(f, display: true) }
    }

    /// The window a ghost flies in: covers both ends, but never pokes above the menu bar (macOS would push it down).
    private func flightArea(_ a: NSRect, _ b: NSRect) -> NSRect {
        var area = a.union(b).insetBy(dx: -30, dy: -30)
        let screen = NSScreen.screens.first { $0.frame.intersects(b) } ?? NSScreen.main
        if let top = screen?.visibleFrame.maxY, area.maxY > top { area.size.height -= area.maxY - top }
        return area
    }

    private func snapshot(_ view: NSView?) -> CGImage? {
        guard let view, view.bounds.width > 1, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// How many cats fit on this screen.
    private var maxSlots: Int {
        let vf = (panel?.screen ?? screenUnderMouse())?.visibleFrame.width ?? 1440
        return max(1, Int((vf - 16 - Layout.pad * 2 - Layout.newJobWidth - Layout.minimizeWidth) / (Layout.slotWidth + Layout.gap)))
    }

    /// Picks up new and finished agents, gives each new one its own cat, and resizes the bar and the strip.
    private func sync() {
        var shown = TaskEngine.shared.tasks
        if shown.count > maxSlots {
            // Too many to show: drop the oldest finished ones first.
            while shown.count > maxSlots, let i = shown.firstIndex(where: \.isFinished) { shown.remove(at: i) }
            shown = Array(shown.suffix(maxSlots))
        }
        let changed = shown.map(\.id) != model.tasks.map(\.id)
        for task in shown where model.coats[task.id] == nil {
            let used = Set(shown.compactMap { model.coats[$0.id] })
            model.coats[task.id] = (0..<PixelCat.coats.count).first { !used.contains($0) } ?? model.coats.count % PixelCat.coats.count
        }
        guard changed else { return }
        model.tasks = shown
        if let strip, strip.isVisible {
            WindowMotion.animate(strip, to: stripFrame())
        }
        guard expanded, let panel, panel.isVisible else { return }
        let target = frame(width: width(for: shown.count), on: panel.screen)
        settledFrame = target
        WindowMotion.animate(panel, to: target)
        // Keep an open card under its cat.
        if let id = model.openID, let i = shown.firstIndex(where: { $0.id == id }), card.isShowing {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in self?.openCard(i) }
        }
    }

    private func build() {
        let p = AgentBarPanel(size: NSSize(width: width(for: 0), height: Layout.height), canKey: false)
        p.hasShadow = true
        let h = NSHostingView(rootView: AgentBarView(model: model))
        p.contentView = container(for: h, size: p.frame.size) { [weak self] point in
            guard let self else { return }
            switch self.hit(at: point) {
            case .slot(let i), .close(let i): self.model.hover = .slot(i)
            case .allow(let i): self.model.hover = .allow(i)
            case .deny(let i): self.model.hover = .deny(i)
            case .newJob: self.model.hover = .newJob
            case .minimize: self.model.hover = .minimize
            case nil: self.model.hover = nil
            }
        } exit: { [weak self] in self?.model.hover = nil }
        p.onClick = { [weak self] point in
            if let hit = self?.hit(at: point) { self?.handle(hit) }
        }
        panel = p
        host = h

        let f = stripFrame()
        let s = AgentBarPanel(size: f.size, canKey: false)
        s.hasShadow = true
        let sh = NSHostingView(rootView: AgentStripView(model: model))
        s.contentView = container(for: sh, size: f.size) { [weak self] _ in self?.model.stripHover = true }
            exit: { [weak self] in self?.model.stripHover = false }
        s.setFrame(f, display: false)
        s.onClick = { [weak self] _ in self?.stripClicked() }
        strip = s
        stripHost = sh
    }

    /// A SwiftUI view in a window, with a hover tracker over it.
    private func container(for host: NSView, size: NSSize, move: @escaping (NSPoint) -> Void, exit: @escaping () -> Void) -> NSView {
        let content = NSView(frame: NSRect(origin: .zero, size: size))
        content.wantsLayer = true
        if let h = host as? NSHostingView<AgentBarView> { h.sizingOptions = [] }
        if let h = host as? NSHostingView<AgentStripView> { h.sizingOptions = [] }
        host.autoresizingMask = [.width, .height]
        host.frame = content.bounds
        content.addSubview(host)
        let hover = HoverTracker(frame: content.bounds)
        hover.autoresizingMask = [.width, .height]
        hover.onMove = move
        hover.onExit = exit
        content.addSubview(hover)
        return content
    }

    // MARK: Going away

    private func watchForClicksElsewhere() {
        removeMonitors()
        // Clicks in Margin's own windows (the bar, a card, the job box) aren't seen here; clicks in other apps are.
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.clickedElsewhere() }
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { self?.hide() } // Esc
        }
    }

    /// A click in another app puts the bar away, unless an agent is waiting for your OK: then the bar stays so Allow and
    /// Deny can't slip away (only the card goes; Esc, ⌘⇧A or the minimize button still put the bar away).
    private func clickedElsewhere() {
        if model.tasks.contains(where: { $0.state == .needsApproval }) {
            card.hide()
            TaskBox.shared.hide()
        } else {
            hide()
        }
    }

    private func removeMonitors() {
        clickMonitor.map(NSEvent.removeMonitor)
        keyMonitor.map(NSEvent.removeMonitor)
        clickMonitor = nil
        keyMonitor = nil
    }

    // MARK: Debug hooks (--agentbartest)

    var debugFrame: NSRect { panel?.frame ?? .zero }
    /// A click in another app, as the global mouse monitor would report it.
    func debugClickElsewhere() { clickedElsewhere() }
    var debugStrip: (visible: Bool, alpha: CGFloat, frame: NSRect) { (strip?.isVisible == true, strip?.alphaValue ?? 0, strip?.frame ?? .zero) }
    var debugBarAlpha: CGFloat { panel?.isVisible == true ? panel?.alphaValue ?? 0 : 0 }
    func debugImage() -> NSBitmapImageRep? {
        guard let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep
    }
    func debugStripImage() -> NSBitmapImageRep? {
        guard let stripHost, let rep = stripHost.bitmapImageRepForCachingDisplay(in: stripHost.bounds) else { return nil }
        stripHost.cacheDisplay(in: stripHost.bounds, to: rep)
        return rep
    }
}

/// Clicks are read here, by position, rather than by SwiftUI buttons: the bar never takes the keyboard, and this way
/// the very first click on a cat always counts.
final class AgentBarPanel: FloatingPanel {
    var onClick: ((NSPoint) -> Void)?
    private var downAt: NSPoint?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downAt = event.locationInWindow
        case .leftMouseUp:
            if let d = downAt, hypot(d.x - event.locationInWindow.x, d.y - event.locationInWindow.y) < 6 { onClick?(event.locationInWindow) }
            downAt = nil
        default:
            super.sendEvent(event)
        }
    }
}

/// Reports where the mouse is over the bar (for hover highlights), even though the bar is never the key window.
private final class HoverTracker: NSView {
    var onMove: ((NSPoint) -> Void)?
    var onExit: (() -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func mouseMoved(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseEntered(with event: NSEvent) { onMove?(convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

final class AgentBarModel: ObservableObject {
    enum Hover: Equatable { case slot(Int), allow(Int), deny(Int), newJob, minimize

        /// The slot the mouse is in, whichever part of it.
        var slot: Int? {
            switch self {
            case .slot(let i), .allow(let i), .deny(let i): return i
            case .newJob, .minimize: return nil
            }
        }
    }

    @Published var tasks: [BackgroundTask] = []
    @Published var openID: UUID?
    @Published var hover: Hover?
    /// Running cats only animate while they're on screen: in the bar, or in the strip.
    @Published var visible = false
    @Published var stripVisible = false
    @Published var stripHover = false
    /// Each agent's cat, for as long as it's listed.
    var coats: [UUID: Int] = [:]

    func coat(_ task: BackgroundTask) -> Int { coats[task.id] ?? 0 }

    /// The × shows for anything that isn't busy working (a running agent is stopped from its card).
    func closable(_ i: Int) -> Bool {
        guard tasks.indices.contains(i) else { return false }
        return tasks[i].state != .working || tasks[i].queued
    }
}

// MARK: - Drawing

private let accent = Color(nsColor: Theme.accent)

struct AgentBarView: View {
    @ObservedObject var model: AgentBarModel

    var body: some View {
        HStack(spacing: AgentBar.Layout.gap) {
            if model.tasks.isEmpty {
                empty
            } else {
                ForEach(Array(model.tasks.enumerated()), id: \.element.id) { i, task in
                    AgentSlotView(task: task, coat: model.coat(task), animating: model.visible,
                                  isOpen: model.openID == task.id, hover: model.hover, index: i, closable: model.closable(i))
                }
            }
            newJob
            minimize
        }
        .padding(.horizontal, AgentBar.Layout.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AgentBar.Layout.corner, style: .continuous)
                .fill(Color(white: 0.04))
                .overlay(RoundedRectangle(cornerRadius: AgentBar.Layout.corner, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
        .environment(\.colorScheme, .dark)
    }

    private var empty: some View {
        HStack(spacing: 4) {
            PixelCatView(coat: 0, mood: .idle).frame(width: AgentBar.Layout.catArea)
            VStack(alignment: .leading, spacing: 2) {
                Text("No agents running").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white)
                Text("Click + or say “tidy my desktop”").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.55))
            }
            Spacer(minLength: 0)
        }
        .frame(width: AgentBar.Layout.emptyWidth, height: AgentBar.Layout.height)
    }

    private var newJob: some View {
        let hot = model.hover == .newJob
        return ZStack {
            Circle().fill(Color.white.opacity(hot ? 0.2 : 0.1)).frame(width: 34, height: 34)
            Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(.white.opacity(hot ? 1 : 0.8))
        }
        .frame(width: AgentBar.Layout.newJobWidth, height: AgentBar.Layout.height)
    }

    /// Back to the strip on the right.
    private var minimize: some View {
        let hot = model.hover == .minimize
        return Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(hot ? 0.95 : 0.5))
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.white.opacity(hot ? 0.16 : 0)))
            .frame(width: AgentBar.Layout.minimizeWidth, height: AgentBar.Layout.height)
    }
}

/// The minimized agent bar: a small black strip on the right edge with a little cat per agent.
struct AgentStripView: View {
    @ObservedObject var model: AgentBarModel

    var body: some View {
        VStack(spacing: 0) {
            if model.tasks.isEmpty {
                PixelCatView(coat: 0, mood: .idle, roam: 0, pixels: 3).opacity(0.6)
                    .frame(height: AgentBar.Layout.stripCell)
            } else {
                ForEach(model.tasks.suffix(AgentBar.Layout.stripMaxCats), id: \.id) { task in
                    MiniCatView(task: task, coat: model.coat(task), animating: model.stripVisible)
                        .frame(height: AgentBar.Layout.stripCell)
                }
                if model.tasks.count > AgentBar.Layout.stripMaxCats {
                    Text("+\(model.tasks.count - AgentBar.Layout.stripMaxCats)").font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7)).frame(height: AgentBar.Layout.stripCell)
                }
            }
        }
        .padding(.vertical, AgentBar.Layout.stripPad)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: AgentBar.Layout.stripCorner, style: .continuous)
                .fill(Color(white: model.stripHover ? 0.12 : 0.04))
                .overlay(RoundedRectangle(cornerRadius: AgentBar.Layout.stripCorner, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        )
        .help("Agents: click to open (⌘⇧A)")
    }
}

/// One agent in the strip: a small cat in the same pose as in the bar, with a ? when it needs you.
struct MiniCatView: View {
    @ObservedObject var task: BackgroundTask
    let coat: Int
    let animating: Bool

    var body: some View {
        let mood = AgentSlotView.mood(task)
        PixelCatView(coat: coat, mood: animating || mood != .running ? mood : .paused, roam: 0, pixels: 3)
            .overlay(alignment: .topTrailing) {
                if task.state == .needsApproval {
                    Circle().fill(accent).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.black, lineWidth: 1.5))
                        .offset(x: 2, y: -1)
                }
            }
    }
}

/// One agent: its cat (sitting, running or a loaf), what it's called, and what it's doing. An agent that's waiting for
/// you shows what it wants to do and an Allow and a Deny button right here.
struct AgentSlotView: View {
    @ObservedObject var task: BackgroundTask
    let coat: Int
    let animating: Bool
    let isOpen: Bool
    let hover: AgentBarModel.Hover?
    let index: Int
    let closable: Bool

    private var hovering: Bool { hover?.slot == index }

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                PixelCatView(coat: coat, mood: animating ? Self.mood(task) : Self.restingMood(task), roam: 8)
                if task.state == .needsApproval {
                    Text("?").font(.system(size: 10, weight: .heavy, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 15, height: 15).background(Circle().fill(accent))
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: AgentBar.Layout.catArea)
            if task.state == .needsApproval { asking } else { status }
            Spacer(minLength: 0)
        }
        .frame(width: AgentBar.Layout.slotWidth, height: AgentBar.Layout.height)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(isOpen ? 0.15 : hovering ? 0.08 : 0))
            .padding(.vertical, 5))
        .overlay(alignment: .topTrailing) {
            if hovering && closable && task.state != .needsApproval {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.8))
                    .frame(width: 16, height: 16).background(Circle().fill(Color.white.opacity(0.16)))
                    .padding(9)
            }
        }
    }

    /// Name, what it's doing, progress.
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
            let s = Self.status(task)
            Text(s.text).font(.system(size: 10.5)).foregroundStyle(s.color).lineLimit(1)
            if task.state == .working, !task.queued, let f = task.fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.12))
                        Capsule().fill(accent).frame(width: max(3, g.size.width * f))
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.trailing, 8)
    }

    /// Name, what it wants to do, and the two buttons.
    private var asking: some View {
        let quick = task.canQuickApprove
        return VStack(alignment: .leading, spacing: 0) {
            Text(task.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white).lineLimit(1).frame(height: 15)
            Text(task.approvalSummary).font(.system(size: 10)).foregroundStyle(accent).lineLimit(1).frame(height: 13)
            Spacer(minLength: 0)
            HStack(spacing: AgentBar.Layout.buttonGap) {
                pill(quick ? "Allow" : "Review", size: AgentBar.Layout.allowSize, filled: true, hot: hover == .allow(index))
                pill("Deny", size: AgentBar.Layout.denySize, filled: false, hot: hover == .deny(index))
            }
        }
        .padding(.top, 9)
        .padding(.bottom, AgentBar.Layout.buttonsBottom)
        .frame(maxHeight: .infinity)
    }

    private func pill(_ title: String, size: CGSize, filled: Bool, hot: Bool) -> some View {
        Text(title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(Capsule().fill(filled ? accent.opacity(hot ? 1 : 0.9) : Color.white.opacity(hot ? 0.26 : 0.15)))
    }

    static func mood(_ task: BackgroundTask) -> PixelCatView.Mood {
        switch task.state {
        case .working: return task.queued ? .idle : .running
        case .needsApproval, .failed, .cancelled: return .idle
        case .done: return .done
        }
    }

    /// While the bar is hidden nothing animates; a running cat is drawn mid-stride.
    static func restingMood(_ task: BackgroundTask) -> PixelCatView.Mood {
        mood(task) == .running ? .paused : mood(task)
    }

    static func status(_ task: BackgroundTask) -> (text: String, color: Color) {
        switch task.state {
        case .working:
            return (task.queued ? "Waiting its turn" : task.detail, .white.opacity(0.6))
        case .needsApproval:
            return ("Needs your OK", accent)
        case .done:
            return (task.undone ? "Undone" : (task.report?.headline ?? "Done"), Color(red: 0.45, green: 0.85, blue: 0.55))
        case .failed(let message):
            return ("Failed: " + message, Color(red: 1, green: 0.45, blue: 0.42))
        case .cancelled:
            return (task.detail == "Starting…" ? "Stopped" : task.detail, .white.opacity(0.55))
        }
    }
}
