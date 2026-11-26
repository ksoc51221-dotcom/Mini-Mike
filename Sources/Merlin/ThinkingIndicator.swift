import SwiftUI

/// The spark path, for SwiftUI.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        return Path(ClaudeMark.path(center: CGPoint(x: rect.midX, y: rect.midY), radius: r))
    }
}

/// "Thinking": a thinking orb (its shape follows what Claude is doing) and a line that shimmers and changes its word
/// every couple of seconds. A `status` (what Claude is actually doing, like "Searching the web…") replaces the words.
struct ThinkingIndicator: View {
    var verbs: [String] = ["Thinking", "Working it out", "Putting it together"]
    var status: String? = nil
    var size: CGFloat = 18
    /// A fixed orb for this place (the Library assistant uses `solving`). nil picks one from `status`.
    var orb: Orb.State? = nil
    /// The answer comes from the local model (Local mode): a calmer orb.
    var local = false

    @State private var index = 0
    private let tick = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    private static func dotted(_ s: String) -> String { s.hasSuffix("…") || s.hasSuffix("...") ? s : s + "…" }

    private var moving: Bool { !Motion.still && !Motion.reduceMotion }

    var body: some View {
        HStack(spacing: 8) {
            ThinkingOrb(state: orb ?? ThinkingOrb.state(forStatus: status, local: local), size: size)
                .accessibilityHidden(true)
            ShimmerText(text: Self.dotted(status ?? verbs[index % max(verbs.count, 1)]))
                .id(status ?? "verb\(index)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity.combined(with: .offset(y: -5))))
        }
        .animation(moving ? .easeInOut(duration: 0.35) : nil, value: index)
        .onReceive(tick) { _ in
            if status == nil, verbs.count > 1 { index = (index + 1) % verbs.count }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "Thinking")
    }
}
