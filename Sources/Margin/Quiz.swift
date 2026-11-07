import SwiftUI

/// A quiz Claude wrote inside a <quiz> tag: a few multiple-choice questions and a short-answer one. Choices are
/// graded here, on this Mac, so grading costs nothing; short answers show Claude's answer and you mark yourself.
struct QuizSpec: Equatable {
    struct Question: Equatable, Identifiable {
        /// Its position in the quiz (stable, since the quiz is parsed again on every redraw).
        let id: Int
        var text: String
        /// Empty for a short-answer question.
        var options: [String]
        /// The right option's index (multiple choice).
        var correct: Int
        /// Claude's answer, in words (what a short-answer question is checked against).
        var answer: String
        var why: String

        var isChoice: Bool { options.count >= 2 && options.indices.contains(correct) }
    }

    var title: String
    var questions: [Question]

    static func == (a: QuizSpec, b: QuizSpec) -> Bool {
        a.title == b.title && a.questions.map(\.text) == b.questions.map(\.text)
    }

    /// nil if there's nothing askable in it.
    static func parse(_ json: String) -> QuizSpec? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = root["questions"] as? [[String: Any]] else { return nil }
        var out: [Question] = []
        for item in raw.prefix(8) {
            guard let text = (item["q"] ?? item["question"]) as? String, !text.isEmpty else { continue }
            let options = (item["options"] as? [Any])?.map { "\($0)" } ?? []
            let why = (item["why"] as? String) ?? ""
            var correct = -1
            var answer = ""
            switch item["answer"] {
            case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID():
                correct = n.intValue
                if options.indices.contains(correct) { answer = options[correct] }
            case let s as String:
                answer = s
                if let i = options.firstIndex(where: { $0.caseInsensitiveCompare(s) == .orderedSame }) {
                    correct = i
                    answer = options[i]
                } else if s.count == 1, let letter = s.uppercased().unicodeScalars.first,
                          (65...72).contains(Int(letter.value)), options.indices.contains(Int(letter.value) - 65) {
                    correct = Int(letter.value) - 65
                    answer = options[correct]
                }
            default:
                break
            }
            guard !answer.isEmpty else { continue }
            out.append(Question(id: out.count, text: text, options: options, correct: correct, answer: answer, why: why))
        }
        guard !out.isEmpty else { return nil }
        return QuizSpec(title: (root["title"] as? String) ?? "Quick quiz", questions: out)
    }
}

extension EnvironmentValues {
    /// Called when a quiz is finished (so Margin can file the score and keep the missed questions).
    var marginQuizFinished: (QuizResult) -> Void {
        get { self[QuizFinishedKey.self] }
        set { self[QuizFinishedKey.self] = newValue }
    }
}

private struct QuizFinishedKey: EnvironmentKey {
    static let defaultValue: (QuizResult) -> Void = { _ in }
}

private let accent = Theme.accent.color
private let accentText = Theme.accentText.color
private let right = Theme.done.color.opacity(0.95)
private let wrong = Theme.alert.color

struct QuizView: View {
    let source: String
    @Environment(\.marginQuizFinished) private var finished
    @State private var index: Int
    @State private var picked: Int?
    @State private var typed = ""
    @State private var revealed: Bool
    @State private var marks: [Int: Bool] = [:]
    @State private var reported = false
    @State private var kept = false

    /// `index`, `picked`, `revealed` and `marks` let the demo show a quiz partway through.
    init(source: String, index: Int = 0, picked: Int? = nil, revealed: Bool = false, marks: [Int: Bool] = [:]) {
        self.source = source
        _index = State(initialValue: index)
        _picked = State(initialValue: picked)
        _revealed = State(initialValue: revealed)
        _marks = State(initialValue: marks)
    }

    var body: some View {
        if let spec = QuizSpec.parse(source) {
            card(spec)
        } else {
            Text("The quiz didn't come out right. Tap Quiz me to try again.")
                .font(.geist(12)).foregroundStyle(Theme.inkSecondary.color)
        }
    }

    private func card(_ spec: QuizSpec) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if index < spec.questions.count {
                question(spec, spec.questions[index])
                    .id(index)
                    .transition(.asymmetric(insertion: .opacity.combined(with: .offset(x: 14)), removal: .opacity))
            } else {
                score(spec)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).fill(Theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).strokeBorder(Theme.hairlineStrong.color, lineWidth: 1))
    }

    // MARK: A question

    private func question(_ spec: QuizSpec, _ q: QuizSpec.Question) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("Quiz · \(spec.title)")
                    .mLabelStyle()
                    .foregroundStyle(Theme.inkSecondary.color)
                    .lineLimit(1)
                Spacer()
                Text("\(index + 1) / \(spec.questions.count)")
                    .font(.mNum).foregroundStyle(Theme.inkSecondary.color)
                    .contentTransition(.numericText())
            }
            Text(q.text)
                .font(.geist(12, .medium))
                .fixedSize(horizontal: false, vertical: true)
            if q.isChoice {
                ForEach(Array(q.options.enumerated()), id: \.offset) { i, option in
                    Button { pick(i, q) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Text(["A", "B", "C", "D", "E", "F"][min(i, 5)])
                                .font(.mMeta.weight(.medium)).foregroundStyle(Theme.inkSecondary.color).frame(width: 14)
                            Text(option).font(.geist(12)).multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            if let mark = optionMark(i, q) {
                                Image(systemName: mark.symbol).foregroundStyle(mark.color)
                            }
                        }
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(optionFill(i, q)).padding(1).background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.hairline.color)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(picked != nil)
                }
                if picked != nil { explanation(q) }
            } else {
                if revealed {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Your answer: " + (typed.isEmpty ? "—" : typed)).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
                        Text(q.answer).font(.geist(12)).fixedSize(horizontal: false, vertical: true)
                        if !q.why.isEmpty { Text(q.why).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(right.opacity(0.14)))
                    if marks[q.id] == nil {
                        HStack(spacing: 6) {
                            gradeButton("I got it", "checkmark", right) { marks[q.id] = true }
                            gradeButton("Missed it", "xmark", wrong) { marks[q.id] = false }
                        }
                    }
                } else {
                    TextField("Your answer…", text: $typed)
                        .textFieldStyle(.plain).font(.geist(12))
                        .padding(.horizontal, 9).padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
                        .onSubmit { withAnimation(.snappy(duration: 0.25)) { revealed = true } }
                    Button("Show answer") { withAnimation(.snappy(duration: 0.25)) { revealed = true } }
                        .buttonStyle(QuizChip(fill: Theme.surfaceRaised.color, text: Theme.ink.color, border: true))
                }
            }
            if canAdvance(q) {
                Button(index + 1 < spec.questions.count ? "Next" : "See my score") { advance(spec) }
                    .buttonStyle(QuizChip(fill: accent, text: Theme.onAccent.color))
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func explanation(_ q: QuizSpec.Question) -> some View {
        Group {
            if picked == q.correct {
                Text(q.why.isEmpty ? "Right." : q.why).foregroundStyle(Theme.inkSecondary.color)
            } else {
                Text("The answer is \(q.options[q.correct]). " + q.why).foregroundStyle(Theme.inkSecondary.color)
            }
        }
        .font(.geist(11.5))
        .fixedSize(horizontal: false, vertical: true)
    }

    private func gradeButton(_ title: String, _ symbol: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button { withAnimation(.snappy(duration: 0.2), action) } label: { Label(title, systemImage: symbol) }
            .buttonStyle(QuizChip(fill: color.opacity(0.2), text: color))
    }

    private func optionMark(_ i: Int, _ q: QuizSpec.Question) -> (symbol: String, color: Color)? {
        guard let picked else { return nil }
        if i == q.correct { return ("checkmark.circle.fill", right) }
        if i == picked { return ("xmark.circle.fill", wrong) }
        return nil
    }

    private func optionFill(_ i: Int, _ q: QuizSpec.Question) -> Color {
        guard let picked else { return Theme.surfaceRaised.color }
        if i == q.correct { return right.opacity(0.16) }
        if i == picked { return wrong.opacity(0.16) }
        return Theme.surfaceRaised.color
    }

    private func pick(_ i: Int, _ q: QuizSpec.Question) {
        guard picked == nil else { return }
        withAnimation(.snappy(duration: 0.22)) {
            picked = i
            marks[q.id] = (i == q.correct)
        }
    }

    private func canAdvance(_ q: QuizSpec.Question) -> Bool {
        q.isChoice ? picked != nil : marks[q.id] != nil
    }

    private func advance(_ spec: QuizSpec) {
        withAnimation(.snappy(duration: 0.28)) {
            index += 1
            picked = nil
            typed = ""
            revealed = false
        }
        if index >= spec.questions.count { report(spec) }
    }

    // MARK: Score

    private func result(_ spec: QuizSpec) -> QuizResult {
        let missed = spec.questions.filter { marks[$0.id] == false }
            .map { QuizResult.Missed(question: $0.text, answer: $0.answer, why: $0.why) }
        return QuizResult(title: spec.title, correct: spec.questions.count - missed.count,
                          total: spec.questions.count, missed: missed)
    }

    private func report(_ spec: QuizSpec) {
        guard !reported else { return }
        reported = true
        finished(result(spec))
    }

    private func score(_ spec: QuizSpec) -> some View {
        let r = result(spec)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Glyph(kind: r.missed.isEmpty ? .check : .spark, size: 14, color: r.missed.isEmpty ? Theme.done.color : Theme.inkSecondary.color)
                Text("\(r.correct) / \(r.total)").font(.mNum.weight(.semibold)).contentTransition(.numericText())
                Text("right").font(.geist(12, .semibold))
            }
            if r.missed.isEmpty {
                Text("Clean sweep.").font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            } else {
                Text("Worth another look:").font(.geist(12, .semibold)).foregroundStyle(Theme.inkSecondary.color)
                ForEach(Array(r.missed.enumerated()), id: \.offset) { _, m in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(m.question).font(.geist(12, .medium)).fixedSize(horizontal: false, vertical: true)
                        Text(m.answer).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text(kept ? "Saved to your library ✓" : "Missed questions are saved to your library.")
                    .font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            }
            Button("Retake") {
                withAnimation(.snappy(duration: 0.28)) {
                    index = 0; picked = nil; typed = ""; revealed = false; marks = [:]; reported = false
                }
            }
            .buttonStyle(QuizChip(fill: Theme.surfaceRaised.color, text: Theme.ink.color, border: true))
        }
        .onAppear { kept = !r.missed.isEmpty }
    }
}

private struct QuizChip: ButtonStyle {
    let fill: Color
    let text: Color
    var border = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(fill).padding(border ? 1 : 0)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(border ? Theme.hairline.color : Color.clear)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
