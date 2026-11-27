import AppKit
import Combine
import SwiftUI

// Part A (b): Merlin agents. A long task ("find five sources on price ceilings and put them in my economics note") goes
// from the quick loop (`start_agent`) to a background agent: the same `AgentLoop` with the worker profile (Sonnet,
// WebSearch and WebFetch, 40 tool calls, 10 minutes, a $1.00 cap the CLI keeps). One agent works at a time; up to three
// more wait in a queue. A small row at the top right shows the task, the step, the time and the tokens, with Stop. The
// result goes in a note: the one the task named (the agent's `note_save`), else a new note "Agent – …". Same rules as
// the quick loop: only the user's words are instructions, a send or a script asks first, no passwords.

final class AgentWorker: ObservableObject {
    struct Job: Equatable {
        let id = UUID()
        let task: String
    }

    static let maxQueue = 3

    @Published private(set) var current: Job?
    @Published private(set) var step = ""
    @Published private(set) var started = Date()
    @Published private(set) var tokens = 0
    @Published private(set) var queue: [Job] = []

    let profile: AgentLoop.Profile
    private let loop = AgentLoop()
    private let makeTools: () -> AgentTools?
    private let saveNote: (String, String) -> String
    private let report: (String) -> Void
    private var wroteNote = false

    /// `makeTools`: fresh tools for one job (nil: Merlin's actions aren't ready). `saveNote`: (note, text) → status line.
    /// `report`: the line at the end of a job.
    init(profile: AgentLoop.Profile = .worker, makeTools: @escaping () -> AgentTools?,
         saveNote: @escaping (String, String) -> String, report: @escaping (String) -> Void) {
        self.profile = profile
        self.makeTools = makeTools
        self.saveNote = saveNote
        self.report = report
    }

    var limitsLine: String {
        "Limits: \(Int(profile.timeLimit / 60)) min" + (profile.budgetUSD.map { String(format: ", $%.2f", $0) } ?? "") + "."
    }

    /// Adds a task. The line goes back to the quick loop, which tells the user.
    func enqueue(_ task: String) -> String {
        let job = Job(task: task)
        if current == nil {
            start(job)
            return "An agent started: \(task). \(limitsLine)"
        }
        guard queue.count < Self.maxQueue else { return "\(Self.maxQueue) agent tasks wait already. Nothing was added." }
        queue.append(job)
        return "An agent is busy. This task waits (\(queue.count) in the queue)."
    }

    /// The Stop button: the job ends now; the next one in the queue starts.
    func stop() { loop.stop() }

    private func start(_ job: Job) {
        guard let tools = makeTools() else {
            report("Merlin's tools aren't ready, so the agent didn't start.")
            return startNext()
        }
        wroteNote = false
        tools.saveNote = { [weak self] note, text in
            self?.wroteNote = true
            return self?.saveNote(note, text) ?? "Notes aren't ready."
        }
        tools.startAgent = nil // an agent doesn't start agents
        tools.onStep = { [weak self] line in DispatchQueue.main.async { self?.step = line } }
        current = job
        step = "Starting"
        started = Date()
        tokens = 0
        loop.onProgress = { [weak self] now, t in
            if let now { self?.step = now }
            self?.tokens = t
        }
        loop.run(job.task, tools: tools, profile: profile) { [weak self] outcome in self?.finished(job, outcome) }
    }

    private func finished(_ job: Job, _ outcome: AgentLoop.Outcome) {
        let cost = loop.lastCostUSD.map { String(format: "$%.2f", $0) } ?? "cost unknown"
        let name = Self.noteName(job.task)
        switch outcome {
        case .done(let text):
            let onlyStop = text.hasPrefix("Stopped:") && text.count < 160
            if wroteNote {
                report("Agent done: \(Self.short(job.task)). It wrote in your note. \(cost).")
            } else if onlyStop {
                report("Agent \(text.prefix(1).lowercased() + text.dropFirst()) \(cost).")
            } else {
                let saved = saveNote(name, Self.noteBody(task: job.task, result: text, cost: cost))
                report("Agent done: \(Self.short(job.task)). \(saved). \(cost).")
            }
        case .question:
            report("The agent didn't read that as a task.")
        case .failed(let line):
            report("The agent stopped: \(line)")
        }
        current = nil
        step = ""
        startNext()
    }

    private func startNext() {
        guard !queue.isEmpty else { return }
        start(queue.removeFirst())
    }

    /// "Agent – find five sources on price" (the first six words).
    static func noteName(_ task: String) -> String {
        "Agent – " + task.split(separator: " ").prefix(6).joined(separator: " ")
    }

    static func short(_ task: String) -> String {
        task.count > 50 ? String(task.prefix(50)) + "…" : task
    }

    static func noteBody(task: String, result: String, cost: String) -> String {
        "Task: \(task)\n\n\(result)\n\n(Merlin agent, \(cost))"
    }

    /// Writes into the note the agent named (found as the user would find it), or a new one.
    static func liveSaveNote(_ note: String, _ text: String) -> String {
        guard let library = CommandRunner.shared?.library else { return "Notes aren't ready" }
        if let s = library.findSheet(note).sheet {
            return library.appendToSheet(s.id, text) ? "Added to the note \(s.name)" : "Couldn't write in \(s.name)"
        }
        guard let s = library.createSheet(named: note, markup: text) else { return "That note needs a name" }
        return "Saved in the note \(s.name)"
    }
}

// MARK: - The agent row (top right, while an agent works)

final class AgentRowPanel {
    private let worker: AgentWorker
    private var panel: NSPanel?
    private var watch: AnyCancellable?

    init(worker: AgentWorker) {
        self.worker = worker
        watch = worker.$current.receive(on: DispatchQueue.main).sink { [weak self] job in
            job == nil ? self?.hide() : self?.show()
        }
    }

    private func show() {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: AgentRowView(worker: worker))
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let f = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: f.maxX - p.frame.width - 16, y: f.maxY - p.frame.height - 12))
        p.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }
}

private struct AgentRowView: View {
    @ObservedObject var worker: AgentWorker

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Agent · " + AgentWorker.short(worker.current?.task ?? ""))
                    .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(worker.step).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    Text(Self.clock(ctx.date.timeIntervalSince(worker.started)) + " · \(worker.tokens / 1000)k tokens"
                         + (worker.queue.isEmpty ? "" : " · \(worker.queue.count) waiting"))
                        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            Button("Stop") { worker.stop() }
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .frame(width: 320, height: 72)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
