import SwiftUI

// MARK: - Environment

private struct FollowUpKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    /// Asks a follow-up question in this chat (set by the chat; nil in the library, where boards are read-only).
    var merlinFollowUp: ((String) -> Void)? {
        get { self[FollowUpKey.self] }
        set { self[FollowUpKey.self] = newValue }
    }
}

// MARK: - The board card in a chat

/// A whiteboard Claude drew: cards and arrows that build up one step at a time, with a caption for each step.
/// Click a card to ask about that step. See `BoardSpec` for the format and the checks it passed.
struct BoardView: View {
    let source: String
    private let spec: BoardSpec?
    /// The step shown first (0-based). Pictures (`Motion.still`) start there; a live chat animates step 1 in.
    private let initialStep: Int
    @State private var step: Int
    @Environment(\.merlinActivity) private var activity

    init(source: String, initialStep: Int = 0) {
        self.source = source
        let spec = BoardSpec.parse(source)
        self.spec = spec
        let first = min(max(initialStep, 0), max((spec?.steps.count ?? 1) - 1, 0))
        self.initialStep = first
        _step = State(initialValue: Motion.still ? first : -1)
    }

    /// The question a card click sends.
    static func followUpQuestion(for title: String) -> String { "Explain this step more: \(title)" }

    var body: some View {
        if let spec {
            card(spec)
        }
    }

    private func card(_ spec: BoardSpec) -> some View {
        let shown = max(step, 0)
        let last = spec.steps.count - 1
        return VStack(alignment: .leading, spacing: 12) {
            // The controls sit above the board, so "Next step" stays under the pointer while the board grows below it.
            HStack(spacing: 6) {
                BoardProgress(count: spec.steps.count, step: shown)
                    .padding(.trailing, 6)
                Button {
                    activity()
                    replay()
                } label: {
                    Text("Replay")
                }
                .buttonStyle(BoardQuietButton())
                .disabled(shown == 0)
                Button {
                    activity()
                    step = min(shown + 1, last)
                } label: {
                    Text("Next step")
                }
                .buttonStyle(BoardPrimaryButton())
                .disabled(shown >= last)
            }
            BoardStage(spec: spec, step: step)
                .padding(.vertical, 2)
            // The chat's own text view, so $…$ maths in a caption is typeset like the rest of the answer.
            MarkdownText(text: spec.steps[shown].caption)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .id(shown)
                .transition(.opacity)
                .animation(Motion.still ? nil : Motion.animation(BoardMotion.enter), value: shown)
        }
        .padding(12)
        .cardSurface()
        .onAppear {
            guard step < 0 else { return }
            if Motion.reduceMotion {
                step = initialStep
            } else {
                // One frame later, so step 1 draws itself in.
                DispatchQueue.main.async { step = initialStep }
            }
        }
    }

    private func replay() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { step = -1 }
        DispatchQueue.main.async { step = 0 }
    }
}

// MARK: - Motion

enum BoardMotion {
    /// Strong ease-out, no bounce: cubic-bezier(0.23, 1, 0.32, 1).
    static func curve(_ duration: Double) -> Animation { .timingCurve(0.23, 1, 0.32, 1, duration: duration) }
    static let enter = curve(0.28)
    static let nodeIn: Double = 0.28
    static let arrowDraw: Double = 0.45
    static let stagger: Double = 0.06
    /// Card corners (the plan's 12 pt; between Theme's control 10 and container 16).
    static let nodeRadius: CGFloat = 12

    /// The animation for something that appears `delay` seconds into a step. Pictures get none; Reduce Motion gets a
    /// short fade with no drawing or movement.
    static func reveal(_ duration: Double, delay: Double) -> Animation? {
        if Motion.still { return nil }
        if Motion.reduceMotion { return .easeOut(duration: 0.12) }
        return curve(duration).delay(delay)
    }
}

// MARK: - Progress bar

private struct BoardProgress: View {
    let count: Int
    let step: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(i <= step ? Theme.ink.color.opacity(0.85) : Theme.hairlineStrong.color)
                    .frame(height: 3)
            }
        }
        .animation(Motion.still ? nil : Motion.animation(BoardMotion.enter), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step + 1) of \(count)")
    }
}

// MARK: - The board itself

/// Cards placed by `BoardLayout`, with the arrows drawn underneath.
private struct BoardStage: View {
    let spec: BoardSpec
    /// -1 before the first step shows.
    let step: Int

    var body: some View {
        let first = spec.firstStep
        let focus = spec.inFocus(at: step)
        let isLast = step == spec.steps.count - 1
        // Order of the cards new in this step, for the stagger.
        let fresh = spec.nodes.filter { first[$0.id] == step }.map(\.id)
        BoardGrid(spec: spec, step: step) {
            ForEach(spec.nodes) { node in
                let rank = Double(fresh.firstIndex(of: node.id) ?? 0)
                BoardNodeCard(node: node,
                              visible: (first[node.id] ?? 0) <= step,
                              dimmed: !isLast && !focus.contains(node.id),
                              delay: rank * BoardMotion.stagger,
                              step: step)
            }
        }
        .background(
            GeometryReader { g in
                let layout = BoardLayout(spec, .init(width: g.size.width))
                ZStack(alignment: .topLeading) {
                    ForEach(Array(layout.arrows.enumerated()), id: \.offset) { i, arrow in
                        let edge = spec.edges.first { $0.from == arrow.from && $0.to == arrow.to } ?? spec.edges[i]
                        let at = spec.firstStep(of: edge)
                        let newest = [edge.from, edge.to].compactMap { fresh.firstIndex(of: $0) }.max() ?? 0
                        BoardArrowView(arrow: arrow, label: edge.label, dashed: edge.dashed,
                                       visible: at <= step,
                                       dimmed: !isLast && at != step && !(focus.contains(edge.to) && focus.contains(edge.from)),
                                       delay: 0.1 + Double(newest) * BoardMotion.stagger,
                                       step: step)
                    }
                }
                .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            }
        )
        .animation(BoardMotion.reveal(BoardMotion.nodeIn, delay: 0), value: step)
    }
}

/// Places one card per node at the frame `BoardLayout` gives it. Its height follows from the width offered and
/// reaches down to the lowest card shown so far.
private struct BoardGrid: Layout {
    let spec: BoardSpec
    let step: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 340
        let layout = BoardLayout(spec, .init(width: width))
        let first = spec.firstStep
        let shown = Set(spec.nodes.map(\.id).filter { (first[$0] ?? 0) <= max(step, 0) })
        return CGSize(width: width, height: layout.height(showing: shown))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = BoardLayout(spec, .init(width: bounds.width))
        for (i, sub) in subviews.enumerated() where spec.nodes.indices.contains(i) {
            guard let f = layout.frames[spec.nodes[i].id] else { continue }
            sub.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), anchor: .topLeading,
                      proposal: ProposedViewSize(width: f.width, height: f.height))
        }
    }
}

private struct BoardNodeCard: View {
    let node: BoardSpec.Node
    let visible: Bool
    let dimmed: Bool
    let delay: Double
    let step: Int
    @Environment(\.merlinFollowUp) private var followUp
    @State private var hovering = false

    private var radius: CGFloat {
        switch node.shape {
        case .circle: return 100 // a pill
        case .box, .note: return BoardMotion.nodeRadius
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Button {
            followUp?(BoardView.followUpQuestion(for: node.title))
        } label: {
            VStack(spacing: 2) {
                Text(node.title)
                    .font(.geist(12.5, .semibold))
                    .foregroundStyle(Theme.ink.color)
                    .lineLimit(2)
                if let sub = node.subtitle {
                    Text(sub)
                        .font(.geist(11))
                        .foregroundStyle(Theme.inkSecondary.color)
                        .lineLimit(2)
                }
            }
            .multilineTextAlignment(.center)
            .minimumScaleFactor(0.85)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The key node's wash sits behind the text (on solid surface, so arrows never show through it).
            .background(ZStack {
                shape.fill(Theme.surface.color)
                shape.fill(node.key ? Theme.accentWash.color : Theme.surfaceRaised.color)
            })
            .overlay(
                shape.strokeBorder(node.key ? Theme.accent.color.opacity(0.7)
                                   : (hovering && followUp != nil ? Theme.hairlineStrong.color : Theme.hairline.color),
                                   style: StrokeStyle(lineWidth: 1, dash: node.shape == .note ? [3, 2] : []))
            )
            .contentShape(shape)
        }
        .buttonStyle(BoardPressStyle())
        .disabled(followUp == nil)
        .onHover { hovering = $0 }
        .help(followUp == nil ? "" : "Ask about this step")
        .accessibilityLabel(node.subtitle.map { "\(node.title), \($0)" } ?? node.title)
        .accessibilityHint(followUp == nil ? "" : "Asks Merlin to explain this step more")
        .opacity(visible ? (dimmed ? 0.5 : 1) : 0)
        .offset(y: visible || Motion.reduceMotion ? 0 : 6)
        .scaleEffect(visible || Motion.reduceMotion ? 1 : 0.97)
        .animation(BoardMotion.reveal(BoardMotion.nodeIn, delay: delay), value: step)
    }
}

/// One arrow: a soft curve that draws itself on, with its head and optional label.
private struct BoardArrowView: View {
    let arrow: BoardLayout.Arrow
    let label: String?
    let dashed: Bool
    let visible: Bool
    let dimmed: Bool
    let delay: Double
    let step: Int

    var body: some View {
        let color = Theme.inkSecondary.color
        ZStack(alignment: .topLeading) {
            // Reduce Motion: the arrow appears whole (a fade), it doesn't draw itself on.
            BoardCurve(arrow: arrow)
                .trim(from: 0, to: visible || Motion.reduceMotion ? 1 : 0)
                .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: dashed ? [4, 3] : []))
                .opacity(visible ? 1 : 0)
                .animation(BoardMotion.reveal(BoardMotion.arrowDraw, delay: delay), value: step)
            BoardArrowHead(arrow: arrow)
                .stroke(color, style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round))
                .opacity(visible ? 1 : 0)
                .animation(BoardMotion.reveal(0.12, delay: delay + BoardMotion.arrowDraw * 0.8), value: step)
            if let label {
                Text(label)
                    .font(.geist(10.5, .medium))
                    .foregroundStyle(Theme.inkSecondary.color)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule(style: .continuous).fill(Theme.surface.color))
                    .position(arrow.labelAt)
                    .opacity(visible ? 1 : 0)
                    .animation(BoardMotion.reveal(0.2, delay: delay + 0.2), value: step)
            }
        }
        .opacity(dimmed ? 0.5 : 1)
        .animation(BoardMotion.reveal(BoardMotion.nodeIn, delay: 0), value: dimmed)
        .accessibilityHidden(true)
    }
}

private struct BoardCurve: Shape {
    let arrow: BoardLayout.Arrow
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: arrow.start)
        p.addCurve(to: arrow.end, control1: arrow.control1, control2: arrow.control2)
        return p
    }
}

/// A small open chevron at the arrow's end, pointing along the curve.
private struct BoardArrowHead: Shape {
    let arrow: BoardLayout.Arrow
    func path(in rect: CGRect) -> Path {
        let tip = arrow.end
        var dx = tip.x - arrow.control2.x, dy = tip.y - arrow.control2.y
        if abs(dx) < 0.01 && abs(dy) < 0.01 { dx = tip.x - arrow.start.x; dy = tip.y - arrow.start.y }
        let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
        let ux = dx / len, uy = dy / len
        let size: CGFloat = 5, spread: CGFloat = 0.55
        var p = Path()
        p.move(to: CGPoint(x: tip.x - size * (ux - spread * uy), y: tip.y - size * (uy + spread * ux)))
        p.addLine(to: tip)
        p.addLine(to: CGPoint(x: tip.x - size * (ux + spread * uy), y: tip.y - size * (uy - spread * ux)))
        return p
    }
}

// MARK: - Buttons

/// Cards press to 0.97, like every button here.
private struct BoardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

/// The one primary action: ink fill.
private struct BoardPrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .semibold))
            .foregroundStyle(Theme.surface.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.ink.color))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.85 : 1) : 0.3)
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}

/// The quiet action: text only, a faint fill on press.
private struct BoardQuietButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(Theme.inkSecondary.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous)
                .fill(configuration.isPressed ? Theme.hairline.color : Color.clear))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
            .scaleEffect(configuration.isPressed ? Motion.pressScale : 1)
            .animation(Motion.animation(Motion.small), value: configuration.isPressed)
    }
}
