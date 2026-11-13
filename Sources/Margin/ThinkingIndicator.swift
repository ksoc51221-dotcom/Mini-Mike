import SwiftUI

/// The spark path, for SwiftUI.
struct SparkShape: Shape {
    func path(in rect: CGRect) -> Path {
        let r = min(rect.width, rect.height) / 2
        return Path(ClaudeMark.path(center: CGPoint(x: rect.midX, y: rect.midY), radius: r))
    }
}

/// "Thinking", the way Claude does it: a spark that turns and breathes, and a line that shimmers and changes its word
/// every couple of seconds. A `status` (what Claude is actually doing, like "Searching the web…") replaces the words.
struct ThinkingIndicator: View {
    var verbs: [String] = ["Thinking", "Working it out", "Putting it together"]
    var status: String? = nil
    var size: CGFloat = 15

    @State private var turn = false
    @State private var breathe = false
    @State private var index = 0
    private let tick = Timer.publish(every: 2.6, on: .main, in: .common).autoconnect()

    private static func dotted(_ s: String) -> String { s.hasSuffix("…") || s.hasSuffix("...") ? s : s + "…" }

    private var moving: Bool { !Motion.still && !Motion.reduceMotion }

    var body: some View {
        HStack(spacing: 8) {
            SparkShape()
                .stroke(Theme.accentText.color, style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(radius: size / 2), lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(turn ? 360 : 0))
                .scaleEffect(breathe ? 1.0 : 0.78)
                .opacity(breathe ? 1 : 0.7)
            ShimmerText(text: Self.dotted(status ?? verbs[index % max(verbs.count, 1)]))
                .id(status ?? "verb\(index)")
                .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)), removal: .opacity.combined(with: .offset(y: -5))))
        }
        .animation(moving ? .easeInOut(duration: 0.35) : nil, value: index)
        .onAppear {
            guard moving else { breathe = true; return }
            withAnimation(.linear(duration: 7).repeatForever(autoreverses: false)) { turn = true }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { breathe = true }
        }
        .onReceive(tick) { _ in
            if status == nil, verbs.count > 1 { index = (index + 1) % verbs.count }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status ?? "Thinking")
    }
}
