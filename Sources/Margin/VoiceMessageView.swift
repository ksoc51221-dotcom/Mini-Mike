import SwiftUI

private let accent = Theme.accent.color
private let onAccent = Theme.onAccent.color
private let inkC = Theme.ink.color
private let inkT = Theme.inkTertiary.color

/// A chat-style voice message: play/pause, a waveform that fills as it plays (tap to scrub),
/// the time, and a SLOW toggle. Below it, the word with its stress mark and IPA.
/// Drag the bubble out to save it as an .m4a, or right-click → Save Audio As….
struct VoiceMessageView: View {
    @ObservedObject var clip: SpeechClip

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            bubble
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(clip.request.text)
                    .font(.mUI.weight(.semibold))
                    .foregroundStyle(Theme.ink.color)
                if let ipa = clip.request.cleanIPA {
                    Text("/\(ipa)/")
                        .font(.geist(12))
                        .foregroundStyle(Theme.inkSecondary.color)
                }
            }
            .padding(.leading, 4)
            .textSelection(.enabled)
            if case .failed(let message) = clip.state {
                Text(message)
                    .font(.mMeta)
                    .foregroundStyle(Theme.alert.color)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var bubble: some View {
        HStack(spacing: 10) {
            Button { clip.togglePlay() } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(accent)
                    if clip.state == .rendering {
                        ProgressView().controlSize(.mini).tint(onAccent)
                    } else {
                        Image(systemName: clip.isPlaying ? "pause.fill" : "play.fill")
                            .font(.geist(11, .semibold))
                            .foregroundStyle(onAccent)
                            .offset(x: clip.isPlaying ? 0 : 1) // optical centering of the triangle
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(clip.state != .ready)
            .help(clip.isPlaying ? "Pause" : "Play")

            Waveform(levels: clip.waveform, progress: clip.progress) { clip.play(from: $0) }
                .frame(height: 24)

            Text(timeLabel)
                .font(.mNum)
                .foregroundStyle(Theme.inkSecondary.color)
                .contentTransition(.numericText())

            Button { clip.toggleSlow() } label: {
                Text("0.7×")
                    .font(.mMeta)
                    .foregroundStyle(clip.slow ? onAccent : Theme.inkSecondary.color)
                    .padding(.horizontal, 5)
                    .frame(height: 20)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(clip.slow ? accent : Color.clear)
                        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(clip.slow ? Color.clear : Theme.hairlineStrong.color, lineWidth: 1)))
            }
            .buttonStyle(.plain)
            .disabled(clip.state == .rendering)
            .help(clip.slow ? "Back to normal speed" : "Play it slowly")
        }
        .padding(.leading, 7)
        .padding(.trailing, 9)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.hairline.color).overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surfaceRaised.color).padding(1)))
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
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(Double(i) / Double(count) < progress ? inkC : inkT.opacity(0.55))
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
