import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Motion

private enum Spring {
    /// Panels: 0.32 / 0.86. Under Reduce Motion only opacity moves (a short fade); in the picture harness nothing animates.
    static var panel: Animation? { pick(.spring(response: 0.32, dampingFraction: 0.86)) }
    /// Small controls: 0.22 / 0.86.
    static var small: Animation? { pick(.spring(response: 0.22, dampingFraction: 0.86)) }
    private static func pick(_ a: Animation) -> Animation? {
        if Motion.still { return nil }
        return Motion.reduceMotion ? .easeOut(duration: 0.12) : a
    }
}

// MARK: - Small pieces (Marginalia tokens only)

private let ink = Theme.ink.color
private let inkSecondary = Theme.inkSecondary.color
private let inkTertiary = Theme.inkTertiary.color
private let raised = Theme.surfaceRaised.color
private let hairline = Theme.hairline.color
private let accent = Theme.accent.color
private let strong = Theme.hairlineStrong.color
private let alertInk = Theme.alert.color

private extension View {
    /// A rounded box with a 1px border, drawn as two fills (never `strokeBorder`).
    func boxed(radius: CGFloat = Theme.Radius.control, fill: Color = raised, border: Color = hairline) -> some View {
        background(
            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill).padding(1)
                .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(border))
        )
    }

    /// A small rectangle (chip radius) with a 1px border, drawn as two fills.
    func chipBox(fill: Color = raised, border: Color = hairline) -> some View {
        background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(fill).padding(1).background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(border)))
    }
}

private struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? Motion.pressScale : 1)
            .animation(Spring.small, value: configuration.isPressed)
    }
}

private struct MButton: View {
    enum Kind { case plain, prominent, destructive }
    let title: String
    var icon: String?
    var kind: Kind = .plain
    var enabled = true
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .medium)) }
                Text(title).font(.mUI.weight(.medium))
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .frame(height: 26)
            .background(backing)
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
        }
        .buttonStyle(PressScale())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .onHover { hover = $0 }
        .animation(Motion.animation(Motion.small), value: hover)
    }

    private var foreground: Color {
        switch kind {
        case .plain: return ink
        case .prominent: return Theme.onAccent.color
        case .destructive: return alertInk
        }
    }

    @ViewBuilder private var backing: some View {
        if kind == .prominent {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(accent)
        } else {
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hover ? Theme.surfaceSelected.color : raised).padding(1)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(hairline))
        }
    }
}

/// A text field: raised, hairlineStrong border and a 1px accent underline that sweeps in on focus.
private struct MField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var lines: ClosedRange<Int> = 1...1
    var onCommit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        TextField(placeholder, text: $text, axis: axis)
            .textFieldStyle(.plain)
            .font(.mUI)
            .foregroundStyle(ink)
            .lineLimit(lines)
            .focused($focused)
            .onSubmit(onCommit)
            .onChange(of: focused) { _, now in if !now { onCommit() } }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(raised).padding(1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(focused ? strong : hairline))
            )
            .overlay(alignment: .bottom) { FocusUnderline(on: focused).padding(.horizontal, 1) }
            .animation(Motion.animation(Motion.small), value: focused)
    }
}

/// Chips that wrap onto new lines.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 400, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        var origins: [CGPoint] = []
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}

/// A removable word: keyword or app.
private struct RuleChip: View {
    let text: String
    let remove: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.mMeta).foregroundStyle(ink)
            Button(action: remove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(hover ? ink : inkTertiary)
                    .frame(width: 14, height: 14).contentShape(Circle())
            }
            .buttonStyle(PressScale())
            .onHover { hover = $0 }
            .help("Remove \(text)")
            .accessibilityLabel("Remove \(text)")
        }
        .padding(.leading, 9)
        .padding(.trailing, 4)
        .padding(.vertical, 3)
        .chipBox()
    }
}

/// A row of chips plus a field that adds one (Return or comma).
private struct ChipEditor: View {
    let placeholder: String
    @Binding var items: [String]
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !items.isEmpty {
                FlowLayout {
                    ForEach(items, id: \.self) { item in
                        RuleChip(text: item) { withAnimation(Spring.small) { items.removeAll { $0 == item } } }
                            .transition(.opacity)
                    }
                }
            }
            MField(placeholder: placeholder, text: $draft, onCommit: add)
                .onChange(of: draft) { _, now in if now.contains(",") { add() } }
        }
    }

    private func add() {
        let parts = draft.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        draft = ""
        guard !parts.isEmpty else { return }
        withAnimation(Spring.small) {
            for p in parts where !items.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) { items.append(p) }
        }
    }
}

private struct FieldLabel: View {
    let text: String
    var note: String?
    init(_ text: String, note: String? = nil) { self.text = text; self.note = note }
    var body: some View {
        HStack(spacing: 6) {
            Text(text).mFieldLabelStyle().help(note ?? "")
            
        }
    }
}

// MARK: - Editor

/// Manage sectors: reorder, name, glyph, describe, rules, merge and delete, and re-file the library.
/// A standalone view for a sheet or panel; it reads and writes `SectorStore` (shared by default) and `Library` through it.
struct SectorEditorView: View {
    @ObservedObject var store: SectorStore
    var onClose: (() -> Void)?

    @State private var expanded: UUID?
    @State private var dragging: UUID?
    @State private var refiling = false
    @State private var undoBanner: (undo: SectorUndo, text: String)?
    @State private var tick = 0 // bumps when the library changes, so counts stay true

    init(store: SectorStore = .shared, expanded: UUID? = nil, showRefile: Bool = false, onClose: (() -> Void)? = nil) {
        self.store = store
        self.onClose = onClose
        _expanded = State(initialValue: expanded)
        _refiling = State(initialValue: showRefile)
    }

    var body: some View {
        let _ = tick
        VStack(spacing: 0) {
            header
            Rectangle().fill(hairline).frame(height: 1)
            ZStack {
                if refiling {
                    RefilePreview(store: store) { undo, count in
                        withAnimation(Spring.panel) {
                            refiling = false
                            if count > 0 { undoBanner = (undo, count == 1 ? "Moved 1 chat." : "Moved \(count) chats.") }
                        }
                    } cancel: {
                        withAnimation(Spring.panel) { refiling = false }
                    }
                    .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : 8)))
                } else {
                    list.transition(.opacity)
                }
            }
            if let banner = undoBanner { undoBar(banner) }
        }
        .background(Theme.canvas.color)
        .onReceive(NotificationCenter.default.publisher(for: Library.changed)) { _ in tick += 1 }
        .onExitCommand {
            if refiling { withAnimation(Spring.panel) { refiling = false } } else { onClose?() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                DecodeText("Sectors", monoSize: 16).mHeadingStyle().foregroundStyle(ink)
                    .help("Where your chats are filed. Describe a sector and Claude files new chats into it.")
            }
            Spacer(minLength: 12)
            MButton(title: "Re-file all", icon: "arrow.triangle.2.circlepath", enabled: !refiling) {
                withAnimation(Spring.panel) { refiling = true; undoBanner = nil }
            }
            .help("Preview where unlocked chats would move to under your rules")
            MButton(title: "New sector", icon: "plus", enabled: !refiling, action: addSector)
            if let onClose { MButton(title: "Done", action: onClose) }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 12)
    }

    private func addSector() {
        var name = "New sector", n = 2
        while store.sector(named: name) != nil { name = "New sector \(n)"; n += 1 }
        guard let made = store.create(name: name) else { return }
        withAnimation(Spring.panel) { expanded = made.id; undoBanner = nil }
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(store.sectors) { s in
                    SectorItem(store: store, sectorID: s.id, expanded: expanded == s.id, dragging: $dragging,
                               toggle: {
                                   withAnimation(Spring.panel) { expanded = (expanded == s.id) ? nil : s.id }
                               },
                               closeEditor: { withAnimation(Spring.panel) { expanded = nil } })
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    // MARK: Undo

    private func undoBar(_ banner: (undo: SectorUndo, text: String)) -> some View {
        HStack(spacing: 10) {
            Text(banner.text).font(.mUI).foregroundStyle(ink)
            Spacer()
            MButton(title: "Undo") {
                store.library.undo(banner.undo)
                withAnimation(Spring.panel) { undoBanner = nil }
            }
            Button { withAnimation(Spring.panel) { undoBanner = nil } } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(inkTertiary).frame(width: 22, height: 22)
            }
            .buttonStyle(PressScale())
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(raised)
        .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
        .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : 8)))
    }
}


/// One tile of the glyph picker.
private struct GlyphTile: View {
    let kind: GlyphKind
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Glyph(kind: kind, size: 20, color: selected ? Theme.canvas.color : ink, animated: selected, active: hover)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(selected ? ink : (hover ? raised : Theme.surface.color)).padding(1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(selected ? ink : hairline))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale())
        .onHover { hover = $0 }
        .animation(Motion.animation(Motion.small), value: hover)
        .help(kind.title)
        .accessibilityLabel(kind.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}


// MARK: - One sector

private struct SectorItem: View {
    @ObservedObject var store: SectorStore
    let sectorID: UUID
    let expanded: Bool
    @Binding var dragging: UUID?
    let toggle: () -> Void
    let closeEditor: () -> Void
    @State private var hover = false

    private var sector: UserSector? { store.sector(sectorID) }

    var body: some View {
        if let s = sector {
            VStack(spacing: 0) {
                headerRow(s)
                if expanded {
                    SectorCard(store: store, sectorID: sectorID, closeEditor: closeEditor)
                        .transition(.opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : -6)))
                }
            }
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(expanded ? raised : (hover ? raised.opacity(0.7) : .clear)).padding(1)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(expanded ? hairline : .clear))
            )
            .opacity(dragging == sectorID ? 0.45 : 1)
            .onHover { hover = $0 }
            .animation(Motion.animation(Motion.small), value: hover)
            .onDrop(of: [.text], delegate: ReorderDelegate(item: sectorID, store: store, dragging: $dragging))
        }
    }

    private func headerRow(_ s: UserSector) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.geist(10, .medium))
                .foregroundStyle(inkTertiary)
                .opacity(hover || dragging == sectorID ? 1 : 0.35)
                .frame(width: 14)
                .help("Drag to reorder")
            Glyph(kind: store.icon(for: s.name), size: 18, color: ink, active: hover || expanded).frame(width: 20)
            Text(s.name).font(Font.mUI.weight(.medium)).foregroundStyle(ink).lineLimit(1)
            Text(s.description)
                .font(.mFieldLabel)
                .foregroundStyle(s.description.isEmpty ? inkTertiary : inkSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            if s.hasRules { Image(systemName: "line.3.horizontal.decrease").font(.system(size: 9)).foregroundStyle(inkTertiary).help("Has filing rules") }
            if let n = Theme.count(store.count(in: s.name)) { Text(n).font(.mMeta).foregroundStyle(inkTertiary).contentTransition(.numericText()) }
            Image(systemName: "chevron.right")
                .font(.geist(9, .semibold))
                .foregroundStyle(inkTertiary)
                .rotationEffect(.degrees(expanded && !Motion.reduceMotion ? 90 : 0))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onDrag {
            dragging = sectorID
            return NSItemProvider(object: s.id.uuidString as NSString)
        }
        .contextMenu {
            Button("Move up") { move(by: -1) }.disabled(isFirst)
            Button("Move down") { move(by: 1) }.disabled(isLast)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(s.name), \(store.count(in: s.name)) chats")
        .accessibilityHint(expanded ? "Collapse" : "Edit this sector")
    }

    private var index: Int? { store.sectors.firstIndex { $0.id == sectorID } }
    private var isFirst: Bool { index == 0 }
    private var isLast: Bool { index == store.sectors.count - 1 }

    private func move(by step: Int) {
        guard let i = index else { return }
        let target = i + step
        guard store.sectors.indices.contains(target) else { return }
        withAnimation(Spring.small) { store.reorder(from: IndexSet(integer: i), to: step > 0 ? target + 1 : target) }
    }
}

/// Moves the dragged sector over this one as the pointer enters it.
private struct ReorderDelegate: DropDelegate {
    let item: UUID
    let store: SectorStore
    @Binding var dragging: UUID?

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != item,
              let from = store.sectors.firstIndex(where: { $0.id == d }),
              let to = store.sectors.firstIndex(where: { $0.id == item }) else { return }
        withAnimation(Spring.small) { store.reorder(from: IndexSet(integer: from), to: to > from ? to + 1 : to) }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

// MARK: - The editor card

private struct SectorCard: View {
    enum Pending: Equatable { case merge(UUID), delete }

    @ObservedObject var store: SectorStore
    let sectorID: UUID
    let closeEditor: () -> Void

    @State private var nameDraft = ""
    @State private var descriptionDraft = ""
    @State private var keywords: [String] = []
    @State private var apps: [String] = []
    @State private var loaded = false
    @State private var nameError: String?
    @State private var pending: Pending?
    @State private var describing = false
    @State private var describeError: String?
    @State private var showAllGlyphs = false

    private var sector: UserSector? { store.sector(sectorID) }
    private var isOther: Bool { sector?.name == Sector.other }

    var body: some View {
        if let s = sector {
            VStack(alignment: .leading, spacing: 16) {
                nameBlock(s)
                styleBlock(s)
                describeBlock(s)
                rulesBlock
                footer(s)
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 14)
            .onAppear(perform: load)
        }
    }

    private func load() {
        guard !loaded, let s = sector else { return }
        loaded = true
        nameDraft = s.name
        descriptionDraft = s.description
        keywords = s.keywords
        apps = s.apps
    }

    // MARK: Blocks

    private func nameBlock(_ s: UserSector) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldLabel("Name", note: isOther ? "The catch-all can't be renamed." : nil)
            if isOther {
                Text(s.name).font(.mUI).foregroundStyle(inkSecondary).padding(.vertical, 6)
            } else {
                MField(placeholder: "Sector name", text: $nameDraft, onCommit: commitName)
                if let nameError { Text(nameError).font(.mMeta).foregroundStyle(alertInk) }
            }
        }
    }

    private func commitName() {
        guard let s = sector, !isOther else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == s.name { nameError = nil; return }
        if store.rename(sectorID, to: trimmed) {
            nameError = nil
            nameDraft = sector?.name ?? trimmed
        } else {
            nameError = trimmed.isEmpty ? "A sector needs a name." : "Another sector already has that name."
            nameDraft = s.name
        }
    }

    /// The glyph picker: 12 tiles in a 6-column grid (36 px), "More" reveals the rest. The picked tile is filled.
    private func styleBlock(_ s: UserSector) -> some View {
        let current = store.icon(for: s.name)
        let all = GlyphKind.sectorPickable
        let firstDozen = Array(all.prefix(12))
        let showing = showAllGlyphs || !firstDozen.contains(current)
        let cols = Array(repeating: GridItem(.fixed(36), spacing: 8), count: 6)
        return VStack(alignment: .leading, spacing: 8) {
            FieldLabel("Glyph", note: current.title.lowercased())
            LazyVGrid(columns: cols, alignment: .leading, spacing: 8) {
                ForEach(showing ? all : firstDozen, id: \.self) { g in
                    GlyphTile(kind: g, selected: g == current) {
                        withAnimation(Spring.small) { store.update(sectorID) { $0.icon = g } }
                    }
                }
            }
            if all.count > 12 && (showAllGlyphs || firstDozen.contains(current)) {
                Button { withAnimation(Spring.small) { showAllGlyphs.toggle() } } label: {
                    Text(showAllGlyphs ? "Fewer" : "More").mFieldLabelStyle().padding(.vertical, 2)
                }
                .buttonStyle(PressScale())
            }
        }
    }

    private func describeBlock(_ s: UserSector) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                FieldLabel("What belongs here", note: "plain words")
                Spacer()
                MButton(title: describing ? "Thinking…" : "Help me describe", icon: "wand.and.stars", enabled: !describing, action: help)
                    .help("One short Claude call, using the titles of up to 8 chats in this sector")
            }
            MField(placeholder: "e.g. statistics, calculus, anything with formulas", text: $descriptionDraft, axis: .vertical, lines: 2...4)
                .onChange(of: descriptionDraft) { _, now in
                    store.update(sectorID) { $0.description = now.trimmingCharacters(in: .whitespacesAndNewlines) }
                }
            if let describeError {
                Text(describeError).font(.mMeta).foregroundStyle(alertInk)
            }
        }
    }

    private func help() {
        guard let s = sector, !describing else { return }
        describing = true
        describeError = nil
        SectorDescriber.describe(sector: s.name, in: store.library) { result in
            describing = false
            switch result {
            case .failure(let failure):
                describeError = failure.localizedDescription
            case .success(let suggestion):
                withAnimation(Spring.panel) {
                    if !suggestion.description.isEmpty { descriptionDraft = suggestion.description }
                    for k in suggestion.keywords where !keywords.contains(where: { $0.caseInsensitiveCompare(k) == .orderedSame }) { keywords.append(k) }
                }
            }
        }
    }

    private var rulesBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Keywords", note: "a chat that mentions one is filed here")
                ChipEditor(placeholder: "Add a word, then Return", items: $keywords)
                    .onChange(of: keywords) { _, now in store.update(sectorID) { $0.keywords = now } }
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel("Apps or sites", note: "e.g. Desmos, desmos.com")
                ChipEditor(placeholder: "Add an app or site, then Return", items: $apps)
                    .onChange(of: apps) { _, now in store.update(sectorID) { $0.apps = now } }
            }
        }
    }

    // MARK: Merge and delete

    @ViewBuilder private func footer(_ s: UserSector) -> some View {
        if isOther {
            EmptyView()
        } else if let pending {
            confirmBar(s, pending)
        } else {
            HStack(spacing: 8) {
                Menu {
                    ForEach(store.sectors.filter { $0.id != sectorID }) { other in
                        Button(other.name) { withAnimation(Spring.panel) { self.pending = .merge(other.id) } }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.merge").font(.system(size: 11, weight: .medium))
                        Text("Merge into…").font(.mUI.weight(.medium))
                    }
                    .foregroundStyle(ink)
                    .padding(.horizontal, 12).frame(height: 26)
                    .boxed(radius: 6)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                MButton(title: "Delete", icon: "trash", kind: .destructive) {
                    withAnimation(Spring.panel) { pending = .delete }
                }
                Spacer()
            }
        }
    }

    private func confirmBar(_ s: UserSector, _ pending: Pending) -> some View {
        let n = store.count(in: s.name)
        let chats = n == 1 ? "1 chat" : "\(n) chats"
        var text = ""
        var verb = ""
        switch pending {
        case .merge(let id):
            let target = store.sector(id)?.name ?? "that sector"
            text = "Merge \(s.name) into \(target)? \(chats) will move to \(target), and \(s.name) goes away."
            verb = "Merge"
        case .delete:
            text = "Delete \(s.name)? \(chats) will move to Other."
            verb = "Delete"
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.mUI).foregroundStyle(ink).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                MButton(title: "Cancel") { withAnimation(Spring.panel) { self.pending = nil } }
                MButton(title: verb, kind: .destructive) {
                    switch pending {
                    case .merge(let id): store.merge(sectorID, into: id)
                    case .delete: store.delete(sectorID)
                    }
                    closeEditor()
                }
                Spacer()
            }
        }
        .padding(12)
        .boxed(radius: 8, fill: Theme.canvas.color, border: alertInk.opacity(0.45))
        .transition(.opacity)
    }
}

// MARK: - Re-file preview

/// "N chats would move": every move with its own checkbox. Nothing happens until Move is pressed.
private struct RefilePreview: View {
    @ObservedObject var store: SectorStore
    let applied: (SectorUndo, Int) -> Void
    let cancel: () -> Void

    @State private var moves: [RefileMove] = []
    @State private var checked: Set<UUID> = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(moves.isEmpty ? "Nothing to move" : (moves.count == 1 ? "1 chat would move" : "\(moves.count) chats would move"))
                        .font(Font.mUI.weight(.semibold)).foregroundStyle(ink)
                    Text(moves.isEmpty ? "Nothing matches your rules that isn't already filed there." : "Chats you filed yourself aren't listed.")
                        .font(.mMeta).foregroundStyle(inkSecondary)
                }
                Spacer()
                if !moves.isEmpty {
                    MButton(title: "All") { checked = Set(moves.map(\.id)) }
                    MButton(title: "None") { checked = [] }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(moves) { m in row(m) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }

            HStack(spacing: 8) {
                Spacer()
                MButton(title: "Cancel", action: cancel)
                MButton(title: checked.count == 1 ? "Move 1 chat" : "Move \(checked.count) chats", kind: .prominent, enabled: !checked.isEmpty) {
                    let undo = store.applyRefile(moves, only: checked)
                    applied(undo, undo.chats.count)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .overlay(alignment: .top) { Rectangle().fill(hairline).frame(height: 1) }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            moves = store.refilePreview()
            checked = Set(moves.map(\.id))
        }
    }

    private func row(_ m: RefileMove) -> some View {
        let isOn = checked.contains(m.id)
                return Button {
            withAnimation(Spring.small) { if isOn { checked.remove(m.id) } else { checked.insert(m.id) } }
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(isOn ? accent : Theme.canvas.color).padding(1)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(isOn ? accent : inkTertiary))
                    if isOn { MarginSparkMark(color: Theme.onAccent.color, size: 9) }
                }
                .frame(width: 15, height: 15)
                Text(m.title).font(.mUI).foregroundStyle(ink).lineLimit(1)
                Spacer(minLength: 8)
                Glyph(kind: store.icon(for: m.from), size: 14, color: inkSecondary)
                Text(m.from).font(.mMeta).foregroundStyle(inkSecondary).lineLimit(1)
                Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(inkTertiary)
                Glyph(kind: store.icon(for: m.to), size: 14, color: ink)
                Text(m.to).font(.mMeta.weight(.medium)).foregroundStyle(ink).lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowStyle())
        .accessibilityLabel("\(m.title), \(m.from) to \(m.to)")
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct RowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(configuration.isPressed ? raised : .clear))
    }
}

// MARK: - Pictures

extension SectorEditorView {
    /// `Margin --sectorshots <dir>`: headless pictures of the editor with made-up data, light and dark. No window is shown,
    /// no Claude is called, and the library is a throwaway one.
    @MainActor
    static func renderShots(to dir: URL) {
        _ = NSApplication.shared
        Motion.still = true
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-sectorshots-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let library = Library(directory: tmp)
        func chat(_ title: String, _ sector: String, app: String = "Safari", quote: String = "", locked: Bool = false) {
            var c = ChatRecord(title: title, sector: sector, app: app, quote: quote, turns: [.init(question: title, answer: "An answer.")])
            c.sectorLocked = locked
            library.save(c)
        }
        chat("Standard deviation vs variance", "Math", quote: "the sample variance divides by n - 1")
        chat("Chain rule on a nested exponent", "Math")
        chat("Why integrals are antiderivatives", "Math")
        chat("Plotting a parabola", "Other", app: "Desmos")
        chat("Fitting a regression line", "Other", quote: "least squares regression")
        chat("Closures capture variables", "Computer Science")
        chat("Pronouncing замок", "Language")
        chat("Supply shifts and equilibrium", "Economics", locked: true)
        chat("Past perfect in Russian", "Language")
        let store = SectorStore(directory: tmp, library: library)
        store.update(store.sector(named: "Math")!.id) {
            $0.description = "Statistics, calculus, anything with formulas"
            $0.keywords = ["variance", "regression", "integral", "derivative"]
            $0.apps = ["Desmos", "desmos.com"]
        }
        store.update(store.sector(named: "Language")!.id) { $0.description = "Grammar, pronunciation and vocabulary in any language" }
        store.update(store.sector(named: "Computer Science")!.id) { $0.keywords = ["closure", "python"] }
        if let made = store.create(name: "Thesis", description: "Reading and notes for my dissertation") { store.update(made.id) { $0.icon = .compass } }
        let math = store.sector(named: "Math")!.id
        let language = store.sector(named: "Language")!.id

        let shots: [(String, SectorEditorView)] = [
            ("sectors-1-list", SectorEditorView(store: store)),
            ("sectors-2-editing", SectorEditorView(store: store, expanded: math)),
            ("sectors-3-refile", SectorEditorView(store: store, showRefile: true)),
            ("sectors-4-other-editing", SectorEditorView(store: store, expanded: language)),
        ]
        let modes: [(String, ColorScheme, NSAppearance)] = [("light", .light, NSAppearance(named: .aqua)!), ("dark", .dark, NSAppearance(named: .darkAqua)!)]
        var saved = 0
        for (mode, scheme, appearance) in modes {
            NSApp.appearance = appearance
            for (name, view) in shots {
                let size = CGSize(width: 580, height: name == "sectors-2-editing" ? 900 : 600)
                var image: CGImage?
                appearance.performAsCurrentDrawingAppearance {
                    image = hostedImage(view.frame(width: size.width, height: size.height).environment(\.colorScheme, scheme), size: size, appearance: appearance)
                }
                let file = dir.appendingPathComponent("\(name)-\(mode).png")
                if let image, (try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)) != nil {
                    saved += 1
                    print("wrote \(file.path)")
                } else {
                    print("FAILED \(file.path)")
                }
            }
        }
        print("sector shots: \(saved) of \(shots.count * modes.count) written to \(dir.path)")
    }

    /// Real AppKit text fields only draw in a hosting view; this one is never put in a window.
    @MainActor
    private static func hostedImage<V: View>(_ view: V, size: CGSize, appearance: NSAppearance) -> CGImage? {
        let host = NSHostingView(rootView: view)
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.settleLayout(passes: 4, interval: 0.12)
        return host.snapshotRep()?.cgImage
    }
}
