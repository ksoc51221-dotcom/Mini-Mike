import SwiftUI

/// Margin's "done": no tick. An empty ring closes into a solid disc, the Margin spark turns in at its centre, and one ripple
/// leaves the edge. Empty ring = not yet; solid disc with the spark = done. Still when motion is reduced.
struct MarginDoneBadge: View {
    var on: Bool
    var size: CGFloat = 16
    /// The disc, and the spark's colour on it.
    var ink: Color = Ink.onSurface
    var mark: Color = Theme.canvas.color

    @State private var appeared = Motion.still || Motion.reduceMotion
    @State private var rippleScale: CGFloat = 1
    @State private var rippleOpacity: Double = 0

    private var moving: Bool { !(Motion.still || Motion.reduceMotion) }
    private var lit: Bool { on && appeared }

    var body: some View {
        ZStack {
            Circle().strokeBorder(Ink.outline, lineWidth: 1.2).opacity(lit ? 0 : 1)
            Circle().stroke(ink, lineWidth: 1.2).scaleEffect(rippleScale).opacity(rippleOpacity)
            Circle().fill(ink).scaleEffect(lit ? 1 : 0.15).opacity(lit ? 1 : 0)
            SparkShape()
                .stroke(mark, style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(radius: size * 0.27), lineCap: .round))
                .frame(width: size * 0.54, height: size * 0.54)
                .rotationEffect(.degrees(lit || !moving ? 0 : -75))
                .scaleEffect(lit ? 1 : 0.2)
                .opacity(lit ? 1 : 0)
        }
        .frame(width: size, height: size)
        .animation(moving ? .spring(response: 0.42, dampingFraction: 0.66) : nil, value: lit)
        .onAppear { if !appeared { DispatchQueue.main.async { appeared = true } } }
        .onChange(of: lit) { _, now in if now { ripple() } }
        .accessibilityLabel(on ? "Done" : "Not done")
    }

    private func ripple() {
        guard moving else { return }
        rippleScale = 1; rippleOpacity = 0.55
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.5)) { rippleScale = 1.9; rippleOpacity = 0 }
        }
    }
}

/// Just the spark, for places that are already a filled box (it turns in when the box fills).
struct MarginSparkMark: View {
    var color: Color
    var size: CGFloat = 11
    @State private var appeared = Motion.still || Motion.reduceMotion

    var body: some View {
        SparkShape()
            .stroke(color, style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(radius: size / 2), lineCap: .round))
            .frame(width: size, height: size)
            .rotationEffect(.degrees(appeared ? 0 : -75))
            .scaleEffect(appeared ? 1 : 0.2)
            .opacity(appeared ? 1 : 0)
            .animation(Motion.still || Motion.reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.66), value: appeared)
            .onAppear { DispatchQueue.main.async { appeared = true } }
            .accessibilityHidden(true)
    }
}
