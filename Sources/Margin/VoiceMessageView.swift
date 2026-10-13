import SwiftUI

private let accent = Color(nsColor: Theme.accent)
private let coral = Color(red: 0.94, green: 0.6, blue: 0.43)

/// A chat-style voice message: play/pause, a waveform that fills as it plays (tap to scrub),
/// the time, and a 🐢 slow toggle. Below it, the word with its stress mark and IPA.
/// Drag the bubble out to save it as an .m4a, or right-click → Save Audio As….
struct VoiceMessageView: View {
    @ObservedObject var clip: SpeechClip

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bubble
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(clip.request.text)
                    .font(.body.weight(.semibold))
                if let ipa = clip.request.cleanIPA {
                    Text("/\(ipa)/")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 4)
            .textSelection(.enabled)
            if case .failed(let message) = clip.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bubble: some View {
        HStack(spacing: 10) {
            Button { clip.togglePlay() } label: {
                ZStack {
                    Circle().fill(.white)
                    if clip.state == .rendering {
                        ProgressView().controlSize(.mini).tint(accent)
                    } else {
                        Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(accent)
                            .offset(x: clip.isPlaying ? 0 : 1) // optical centering of the triangle
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .disabled(clip.state != .ready)
            .help(clip.isPlaying ? "Pause" : "Play")

            Waveform(levels: clip.waveform, progress: clip.progress) { clip.play(from: $0) }
                .frame(height: 24)

            Text(timeLabel)
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.92))

            Button { clip.toggleSlow() } label: {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(clip.slow ? accent : .white)
                    .frame(width: 26, height: 20)
                    .background(Capsule().fill(.white.opacity(clip.slow ? 1 : 0.22)))
            }
            .buttonStyle(.plain)
            .disabled(clip.state == .rendering)
            .help(clip.slow ? "Back to normal speed" : "Play it slowly")
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(Capsule().fill(LinearGradient(colors: [accent, coral], startPoint: .leading, endPoint: .trailing)))
        .shadow(color: accent.opacity(0.25), radius: 6, y: 2)
        .onDrag {
            guard let url = clip.fileURL else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
        .contextMenu {
            Button("Save Audio As…") { clip.saveAs() }.disabled(clip.fileURL == nil)
        }
    }

    /// Total length, counting down while it plays (like a chat voice note).
    private var timeLabel: String {
        let remaining = clip.isPlaying ? clip.duration * (1 - clip.progress) : clip.duration
        let seconds = Int(remaining.rounded(.up))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct Waveform: View {
    let levels: [CGFloat]
    let progress: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { g in
            let count = max(levels.count, 1)
            let spacing: CGFloat = 2
            let barWidth = max(1.5, (g.size.width - spacing * CGFloat(count - 1)) / CGFloat(count))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { i in
                    Capsule()
                        .fill(.white.opacity(Double(i) / Double(count) < progress ? 1 : 0.45))
                        .frame(width: barWidth, height: max(3, g.size.height * levels[i]))
                }
            }
            .frame(width: g.size.width, height: g.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                seek(min(1, max(0, Double(v.location.x / g.size.width))))
            })
        }
        .animation(.easeOut(duration: 0.4), value: levels)
    }
}

/// An answer: markdown text, with Claude's <say> tags turned into voice messages.
struct AnswerView: View {
    let text: String
    let streaming: Bool
    let speech: SpeechStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(Answer.pieces(text, hidePartial: streaming).enumerated()), id: \.offset) { _, piece in
                switch piece {
                case .text(let t):
                    MarkdownText(text: t.trimmingCharacters(in: .newlines), streaming: streaming)
                case .say(let request):
                    VoiceMessageView(clip: speech.clip(for: request))
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                case .graph(let source):
                    GraphView(source: source)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                case .drawing:
                    ShimmerText(text: "Drawing a graph…")
                        .transition(.opacity)
                case .quiz(let source):
                    QuizView(source: source)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                case .event(let source):
                    EventCard(source: source)
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                case .writingQuiz:
                    ShimmerText(text: "Writing a quiz…")
                        .transition(.opacity)
                }
            }
        }
    }
}
