import AppKit
import SwiftUI

/// The background agents' own home, separate from the chat sidebar. Minimized, each agent is a cat asleep (and breathing) on the
/// bottom edge of the screen, in the right-hand corner, with nothing around it. Expanded, it's a black bar at the top
/// centre of the screen where each agent is a bigger cat: click one for its card, + for a new job.
/// ⌘⇧A, clicking a resting cat, or asking by voice expands it; clicking elsewhere, Esc, ⌘⇧A or its − button
/// puts the cats back to sleep in the corner (unless they've run away: ⌘⇧C calls them back). The agents keep working either way.
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

        // The resting cats: asleep in the bottom-right corner while the bar is minimized.
        /// Tenths of a point per picture pixel: 4 makes each of the sheet's pixels 2 points, and a cat about 155 points wide.
        /// Breathing moves it one of those pixels (2 points).
        static let restPixels = 4
        /// How far apart neighbouring cats sit: closer than their pictures are wide, so they curl up next to each other.
        static let restSpacing: CGFloat = 140
        static let restMaxCats = 4
        /// Room for "+2" when there are more agents than cats shown.
        static let restMoreWidth: CGFloat = 34
        /// Between the right-most cat's picture and the screen's right edge: the cat sits a little in from the corner.
        static let restInset: CGFloat = 20
        /// The picture's empty margin under the paws, so they sit right on the bottom of the screen.
        static let restSink: CGFloat = 8
        /// Hover over the cats this long and they wake up and run off the right edge of the screen.
        static let wakeAfter = 6.0
        /// Tenths of a point per picture pixel for the awake cats (the standing and running pictures are 1.4x resampled, so 14
        /// makes a sheet pixel about 2 points, like the sleepers).
        static let awakePixels = 14
        /// How fast the cats run, in points per second.
        static let runSpeed: CGFloat = 330
    }

    /// Where the resting cats go: the bottom-right corner of `screen` (a screen's whole frame, so they sit at the very bottom),
    /// a little in from the right edge, growing to the left.
    static func restFrame(count: Int, in screen: NSRect) -> NSRect {
        let cell = CGSize(width: PixelCat.bigCell.width * CGFloat(Layout.restPixels) / 10, height: PixelCat.bigCell.height * CGFloat(Layout.restPixels) / 10)
        let cats = max(1, min(count, Layout.restMaxCats))
        let width = (CGFloat(cats - 1) * Layout.restSpacing + cell.width + (count > Layout.restMaxCats ? Layout.restMoreWidth : 0)).rounded(.up)
        return NSRect(x: (screen.maxX - Layout.restInset - width).rounded(), y: screen.minY - Layout.restSink, width: width, height: cell.height.rounded(.up))
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
    private var hoverWork: DispatchWorkItem?
    private var restWork: DispatchWorkItem?
    private var restTimer: Timer?
    /// The cats have run away for good: only ⌘⇧C brings them back (it survives quitting Margin).
    private(set) var catsGone = UserDefaults.standard.bool(forKey: "catsGone") {
        didSet {
            UserDefaults.standard.set(catsGone, forKey: "catsGone")
            Hotkeys.catGone = catsGone
        }
    }
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
        Hotkeys.catGone = catsGone
        if catsGone {
            model.restPhase = .away
            return
        }
        placeStrip()
        strip?.alphaValue = 1
        strip?.orderFrontRegardless()
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
        cancelRest()
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
            let g = Ghost(image: from, frame: start, radius: 0, gravity: .resizeAspect, area: flightArea(start, target))
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
        if catsGone { // the cats ran away: there's nothing to minimize into
            panel.alphaValue = 0
            panel.orderOut(nil)
            model.visible = false
            return
        }
        placeStrip()
        guard let strip else { return }
        strip.alphaValue = 0
        strip.orderFrontRegardless()
        stripHost?.layoutSubtreeIfNeeded()
        let start = panel.frame
        if panel.isVisible, let from = snapshot(host), let to = snapshot(stripHost) {
            panel.alphaValue = 0
            panel.orderOut(nil)
            model.visible = false
            let g = Ghost(image: from, frame: start, radius: Layout.corner, gravity: .resize, area: flightArea(start, strip.frame))
            ghost = g
            g.animate(to: strip.frame, radius: 0, crossfadeTo: to, gravity: .resizeAspect, duration: 0.3,
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

    /// The resting cats sit in the bottom-right corner of the main screen.
    func stripFrame() -> NSRect {
        let frame = (NSScreen.main ?? NSScreen.screens.first)?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return Self.restFrame(count: model.tasks.count, in: frame)
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
        if let strip, strip.isVisible, model.restPhase == .asleep {
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
        p.onPress = { [weak self] point in
            guard let self else { return }
            switch point.flatMap({ self.hit(at: $0) }) {
            case .allow(let i): self.model.pressed = .allow(i)
            case .deny(let i): self.model.pressed = .deny(i)
            default: self.model.pressed = nil
            }
        }
        panel = p
        host = h

        let f = stripFrame()
        let s = AgentBarPanel(size: f.size, canKey: false)
        s.hasShadow = false // nothing around the cats: a window shadow would draw a box
        s.keepsBelowMenuBar = false // the cats run off the edge of the screen
        let sh = NSHostingView(rootView: AgentStripView(model: model))
        s.contentView = container(for: sh, size: f.size) { [weak self] _ in self?.stripHovered(true) }
            exit: { [weak self] in self?.stripHovered(false) }
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

    // MARK: The cats run away

    /// The mouse is over the cats (or left them). Staying for `wakeAfter` seconds wakes them.
    private func stripHovered(_ inside: Bool) {
        model.stripHover = inside
        if !inside {
            hoverWork?.cancel()
            hoverWork = nil
            return
        }
        guard hoverWork == nil, !expanded, model.restPhase == .asleep else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.hoverWork = nil
            self?.wakeCats()
        }
        hoverWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Layout.wakeAfter, execute: work)
    }

    private func later(_ seconds: Double, _ body: @escaping () -> Void) {
        restWork?.cancel()
        let work = DispatchWorkItem(block: body)
        restWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// They wake and stand up, then run off to the right.
    private func wakeCats() {
        guard !expanded, model.restPhase == .asleep, strip != nil else { return }
        model.restPhase = .waking
        later(0.9) { [weak self] in self?.runOut() }
    }

    private func runOut() {
        guard !expanded, let strip, let edge = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxX else { return }
        model.stripHover = false
        model.restPhase = .leaving
        let distance = edge - strip.frame.minX
        slide(strip, toX: edge, duration: max(1.0, Double(distance / Layout.runSpeed)), accelerating: true) { [weak self] in
            strip.orderOut(nil)
            self?.model.restPhase = .away
            self?.catsGone = true
            Toast.show("The cat left. ⌘⇧C calls it back.", near: NSRect(x: edge - 300, y: strip.frame.maxY + 70, width: 1, height: 1))
        }
    }

    /// ⌘⇧C: the cat that ran away comes back, trotting in from the right.
    func callCats() {
        guard catsGone else { return }
        catsGone = false
        guard !expanded else { return } // the bar is open: the cats are in the corner when it's put away
        runBack()
    }

    /// Trot in from the right, sit, then curl up again.
    private func runBack() {
        guard !expanded, let strip, let edge = (NSScreen.main ?? NSScreen.screens.first)?.frame.maxX else { return }
        let rest = stripFrame()
        strip.setFrame(NSRect(x: edge, y: rest.minY, width: rest.width, height: rest.height), display: true)
        strip.alphaValue = 1
        model.restPhase = .returning
        strip.orderFrontRegardless()
        slide(strip, toX: rest.minX, duration: max(1.0, Double((edge - rest.minX) / Layout.runSpeed)), accelerating: false) { [weak self] in
            self?.model.restPhase = .settling
            self?.later(0.9) { self?.model.restPhase = .asleep }
        }
    }

    /// Moves the strip sideways by hand (so it can be stopped): starting slowly then trotting off, or running in and slowing down.
    private func slide(_ window: NSWindow, toX x: CGFloat, duration: Double, accelerating: Bool, done: @escaping () -> Void) {
        restTimer?.invalidate()
        let from = window.frame
        let began = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self, weak window] timer in
            guard let window else { return timer.invalidate() }
            let p = min(1, (CACurrentMediaTime() - began) / duration)
            let e = accelerating ? p * p : 1 - (1 - p) * (1 - p)
            window.setFrame(NSRect(x: (from.minX + (x - from.minX) * CGFloat(e)).rounded(), y: from.minY, width: from.width, height: from.height), display: true)
            if p >= 1 {
                timer.invalidate()
                self?.restTimer = nil
                done()
            }
        }
        restTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Stops whatever the cats are doing and puts them back asleep in the corner (the bar is opening).
    private func cancelRest() {
        hoverWork?.cancel()
        hoverWork = nil
        restWork?.cancel()
        restWork = nil
        restTimer?.invalidate()
        restTimer = nil
        guard model.restPhase != .asleep, !catsGone else { return }
        model.restPhase = .asleep
        strip?.setFrame(stripFrame(), display: false)
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
    /// The point of a mouse-down while the button is held, nil once it is released (for the Allow / Deny press feedback).
    var onPress: ((NSPoint?) -> Void)?
    private var downAt: NSPoint?

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            downAt = event.locationInWindow
            onPress?(event.locationInWindow)
        case .leftMouseUp:
            onPress?(nil)
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
    /// The Allow / Deny button the mouse is held down on.
    @Published var pressed: Hover?
    /// Running cats only animate while the bar is on screen.
    @Published var visible = false
    @Published var stripHover = false
    /// What the resting cats are doing: asleep, or awake and running out of the screen (and back).
    enum RestPhase { case asleep, waking, leaving, away, returning, settling }
    @Published var restPhase = RestPhase.asleep
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

private let accent = Theme.accent.color
private let onAccent = Theme.onAccent.color
/// The bar is ink in both appearances.
private let barInk = Theme.ink.color
private let barInk2 = Theme.inkSecondary.color
private let barRaised = Theme.surfaceRaised.color
private let barHair = Theme.hairline.color

/// The cats wear a white sticker outline that vanishes on the off-white bar, so in light mode they sit on a quiet raised plate.
private struct CatPlate: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            if scheme == .light {
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surfaceRaised.color).padding(.vertical, 8).padding(.horizontal, 4)
            }
        }
    }
}

struct AgentBarView: View {
    @ObservedObject var model: AgentBarModel

    var body: some View {
        HStack(spacing: AgentBar.Layout.gap) {
            if model.tasks.isEmpty {
                empty
            } else {
                ForEach(Array(model.tasks.enumerated()), id: \.element.id) { i, task in
                    AgentSlotView(task: task, coat: model.coat(task), animating: model.visible,
                                  isOpen: model.openID == task.id, hover: model.hover, pressed: model.pressed, index: i, closable: model.closable(i))
                }
            }
            newJob
            minimize
        }
        .padding(.horizontal, AgentBar.Layout.pad)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            // Two fills for the 1px border (a stroked rounded shape rasterizes with notches).
            ZStack {
                RoundedRectangle(cornerRadius: AgentBar.Layout.corner, style: .continuous).fill(Theme.hairlineStrong.color)
                RoundedRectangle(cornerRadius: AgentBar.Layout.corner - 1, style: .continuous).fill(Theme.canvas.color).padding(1)
            }
        )
    }

    private var empty: some View {
        HStack(spacing: 4) {
            PixelCatView(coat: 0, mood: .idle).frame(width: AgentBar.Layout.catArea).modifier(CatPlate())
            VStack(alignment: .leading, spacing: 2) {
                Text("No agents running").font(.geist(12, .semibold)).foregroundStyle(barInk)
                Text("Click + or say “tidy my desktop”").font(.geist(12, .medium)).foregroundStyle(barInk2)
            }
            Spacer(minLength: 0)
        }
        .frame(width: AgentBar.Layout.emptyWidth, height: AgentBar.Layout.height)
    }

    private var newJob: some View {
        let hot = model.hover == .newJob
        return ZStack {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hot ? Theme.surfaceSelected.color : barRaised).frame(width: 34, height: 34)
            Image(systemName: "plus").font(.geist(15, .semibold)).foregroundStyle(hot ? barInk : barInk2)
        }
        .frame(width: AgentBar.Layout.newJobWidth, height: AgentBar.Layout.height)
    }

    /// Back to the strip on the right.
    private var minimize: some View {
        let hot = model.hover == .minimize
        return Image(systemName: "arrow.down.right.and.arrow.up.left").font(.geist(11, .semibold))
            .foregroundStyle(hot ? barInk : barInk2)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(hot ? barRaised : Color.clear))
            .frame(width: AgentBar.Layout.minimizeWidth, height: AgentBar.Layout.height)
    }
}

/// The minimized agents: a cat asleep for each one, sitting on the bottom edge of the screen with nothing around it. Newer cats
/// are to the right; with no agents there is still one cat, asleep.
struct AgentStripView: View {
    @ObservedObject var model: AgentBarModel

    var body: some View {
        let cell = PixelCat.bigCell.width * CGFloat(AgentBar.Layout.restPixels) / 10
        let hidden = model.tasks.count - AgentBar.Layout.restMaxCats
        HStack(alignment: .bottom, spacing: 0) {
            if hidden > 0 {
                Text("+\(hidden)").font(.mNum.weight(.semibold)).foregroundStyle(barInk)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.canvas.color.opacity(0.85)))
                    .frame(width: AgentBar.Layout.restMoreWidth).padding(.bottom, 40)
            }
            HStack(alignment: .bottom, spacing: AgentBar.Layout.restSpacing - cell) {
                if model.tasks.isEmpty {
                    RestingCat(coat: 0, phase: model.restPhase)
                } else {
                    ForEach(model.tasks.suffix(AgentBar.Layout.restMaxCats), id: \.id) { task in
                        RestingCatView(task: task, coat: model.coat(task), phase: model.restPhase)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .brightness(model.stripHover ? 0.08 : 0)
        .animation(Motion.animation(Motion.small), value: model.stripHover)
        .animation(Motion.animation(Motion.small), value: model.restPhase)
        .help("Agents: click to open (⌘⇧A)")
    }
}

/// One agent's resting cat: asleep and breathing whatever the agent is doing (the bar shows the real pose), with an alert badge
/// when it needs you.
struct RestingCatView: View {
    @ObservedObject var task: BackgroundTask
    let coat: Int
    var phase = AgentBarModel.RestPhase.asleep

    var body: some View {
        RestingCat(coat: coat, phase: phase)
            .overlay(alignment: .topTrailing) {
                if task.state == .needsApproval, phase == .asleep {
                    Text("?").font(.geist(13, .semibold)).foregroundStyle(Theme.onAccent.color)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.alert.color))
                        .background(Circle().fill(Theme.canvas.color).padding(-1.5))
                        .offset(x: -8, y: 14)
                }
            }
    }
}

/// A resting cat in whatever it is doing: asleep, sitting up (just woken, or just back), or running out of the screen (facing
/// right) and back in (facing left).
struct RestingCat: View {
    let coat: Int
    let phase: AgentBarModel.RestPhase

    var body: some View {
        switch phase {
        case .asleep, .away:
            SleepingCatView(coat: coat, pixels: AgentBar.Layout.restPixels, offset: Double(coat) * 0.37)
        case .waking, .settling:
            AwakeCatView(coat: coat, act: .sit)
        case .leaving:
            AwakeCatView(coat: coat, act: .runRight)
        case .returning:
            AwakeCatView(coat: coat, act: .runLeft)
        }
    }
}

/// An awake cat from the small sheet, drawn at the same size as the sleepers: sitting up, or trotting (the pictures face left).
struct AwakeCatView: View {
    enum Act { case sit, runLeft, runRight }
    let coat: Int
    let act: Act

    static func size() -> CGSize {
        CGSize(width: PixelCat.cell.width * CGFloat(AgentBar.Layout.awakePixels) / 10, height: PixelCat.cell.height * CGFloat(AgentBar.Layout.awakePixels) / 10)
    }

    var body: some View {
        Group {
            switch act {
            case .sit:
                sprite(.sit)
            case .runLeft, .runRight:
                TimelineView(.periodic(from: .now, by: 1.0 / 15)) { context in
                    let frame = Int(context.date.timeIntervalSinceReferenceDate * 10) % PixelCat.runFrames
                    sprite(.run(frame)).scaleEffect(x: act == .runRight ? -1 : 1, y: 1)
                }
            }
        }
        .frame(width: Self.size().width, height: Self.size().height)
    }

    @ViewBuilder private func sprite(_ pose: PixelCat.Pose) -> some View {
        if let image = PixelCat.image(coat: coat, pose: pose) {
            Image(decorative: image, scale: 10 / CGFloat(AgentBar.Layout.awakePixels)).interpolation(.high)
        }
    }
}

/// One agent: its cat (standing, running, a loaf, or asleep while it waits its turn), what it's called, and what it's doing. An agent that's waiting for
/// you shows what it wants to do and an Allow and a Deny button right here.
struct AgentSlotView: View {
    @ObservedObject var task: BackgroundTask
    let coat: Int
    let animating: Bool
    let isOpen: Bool
    let hover: AgentBarModel.Hover?
    var pressed: AgentBarModel.Hover? = nil
    let index: Int
    let closable: Bool

    private var hovering: Bool { hover?.slot == index }

    var body: some View {
        HStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                PixelCatView(coat: coat, mood: animating ? Self.mood(task) : Self.restingMood(task), roam: 8)
                if task.state == .needsApproval {
                    Text("?").font(.geist(10, .semibold)).foregroundStyle(onAccent)
                        .frame(width: 15, height: 15).background(Circle().fill(Theme.alert.color))
                        .offset(x: -2, y: 2)
                }
            }
            .frame(width: AgentBar.Layout.catArea)
            .modifier(CatPlate())
            if task.state == .needsApproval { asking } else { status }
            Spacer(minLength: 0)
        }
        .frame(width: AgentBar.Layout.slotWidth, height: AgentBar.Layout.height)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill((isOpen ? Theme.surfaceSelected.color : hovering ? barRaised : Color.clear))
            .padding(.vertical, 5))
        .overlay(alignment: .topTrailing) {
            if hovering && closable && task.state != .needsApproval {
                Image(systemName: "xmark").font(.geist(8, .semibold)).foregroundStyle(barInk2)
                    .frame(width: 16, height: 16).background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(barRaised))
                    .padding(9)
            }
        }
    }

    /// Name, what it's doing, progress.
    private var status: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(task.title).font(.geist(12, .semibold)).foregroundStyle(barInk).lineLimit(1)
            let s = Self.status(task)
            Text(s.text).font(.geist(12, .medium)).foregroundStyle(s.color).lineLimit(1)
            if task.state == .working, !task.queued, let f = task.fraction {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(barHair)
                        RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(barInk).frame(width: max(3, g.size.width * f))
                    }
                    .animation(Motion.animation(Motion.functional), value: f)
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
            Text(task.title).font(.geist(12, .semibold)).foregroundStyle(barInk).lineLimit(1).frame(height: 15)
            Text(task.approvalSummary).font(.geist(12, .medium)).foregroundStyle(barInk2).lineLimit(1).frame(height: 13)
            Spacer(minLength: 0)
            HStack(spacing: AgentBar.Layout.buttonGap) {
                pill(quick ? "Allow" : "Review", size: AgentBar.Layout.allowSize, filled: true, hot: hover == .allow(index), pressed: pressed == .allow(index))
                pill("Deny", size: AgentBar.Layout.denySize, filled: false, hot: hover == .deny(index), pressed: pressed == .deny(index))
            }
        }
        .padding(.top, 9)
        .padding(.bottom, AgentBar.Layout.buttonsBottom)
        .frame(maxHeight: .infinity)
    }

    private func pill(_ title: String, size: CGSize, filled: Bool, hot: Bool, pressed: Bool) -> some View {
        Text(title).font(.geist(12, .semibold)).foregroundStyle(filled ? onAccent : barInk)
            .frame(width: size.width, height: size.height)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(filled ? accent.opacity(hot ? 1 : 0.92) : (hot ? Theme.surfaceSelected.color : barRaised)))
            .scaleEffect(pressed && !Motion.reduceMotion ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: pressed)
            .animation(Motion.animation(Motion.small), value: hot)
    }

    static func mood(_ task: BackgroundTask) -> PixelCatView.Mood {
        switch task.state {
        case .working: return task.queued ? .asleep : .running
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
            return (task.queued ? "Waiting its turn" : task.detail, barInk2)
        case .needsApproval:
            return ("Needs your OK", barInk)
        case .done:
            return (task.undone ? "Undone" : (task.report?.headline ?? "Done"), barInk2)
        case .failed(let message):
            return ("Failed: " + message, Theme.alert.color)
        case .cancelled:
            return (task.detail == "Starting…" ? "Stopped" : task.detail, barInk2)
        }
    }
}
