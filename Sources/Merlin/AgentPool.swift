import AppKit
import Combine
import SwiftUI

// Merlin agents, layer 2: a pool. Up to 3 agents work at once (each its own `AgentLoop` and tool server, on the worker
// profile: Sonnet, the web, 40 tool calls, 10 minutes, $1.00), up to 5 more wait, and the pool starts nothing new after
// $3.00 in one day. Each job has a short name, a state, a step line, the time and the cost, and Stop. A yes/no dialog
// names the agent that asks. The result goes in a note: the one the task named (`note_save`), else "Agent – …".
//
// For the dock (UI/UX builds the view): `jobs` (running and waiting), `history` (the last 10 that ended), `start(_:)`,
// `stop(_:)`, `openResult(_:)`, and `AgentPool.fixtures` (one job in each state) for pictures and tests. All on the main
// thread; `AgentPool` is an `ObservableObject`.

/// One agent job as a view shows it.
struct AgentJobView: Identifiable, Equatable, Codable {
    enum State: String, Equatable, Codable {
        /// In the queue: it starts when one of the 3 places is free.
        case queued
        case working
        /// A yes/no dialog of this agent is open (a send, a script).
        case waiting
        case done
        case stopped
        case failed
    }

    let id: UUID
    /// Three words of the task ("Price ceilings sources").
    var name: String
    var task: String
    var state: State
    /// What it does now, in plain words ("Reading: econlib.org"); at the end, the one-line result.
    var step: String
    var started: Date?
    var ended: Date?
    var tokens: Int
    var costUSD: Double?
    /// The note with the result (open it with `openResult`).
    var resultNote: String?

    var isActive: Bool { state == .queued || state == .working || state == .waiting }

    /// "1:23" since the start (to the end, once it ended).
    func elapsedText(now: Date = Date()) -> String {
        guard let started else { return "0:00" }
        let s = max(0, Int((ended ?? now).timeIntervalSince(started)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    var costText: String { costUSD.map { String(format: "$%.2f", $0) } ?? "\(tokens / 1000)k tokens" }
}

final class AgentPool: ObservableObject {
    static let size = 3
    static let maxQueue = 5
    static let historySize = 10
    static let dailyCapUSD = 3.0

    @Published private(set) var jobs: [AgentJobView] = []
    @Published private(set) var history: [AgentJobView] = []

    let profile: AgentLoop.Profile
    /// Fresh tools for one job: (the agent's name, to put in its dialogs) → tools, or nil if Merlin's actions aren't ready.
    private let makeTools: (String) -> AgentTools?
    private let saveNote: (String, String) -> String
    private let openNote: (String) -> Void
    private let report: (String) -> Void
    private let spend: AgentSpend
    private let store: UserDefaults
    static let historyKey = "agentHistory"
    private var loops: [UUID: AgentLoop] = [:]
    private var wroteNote: [UUID: String] = [:]

    init(profile: AgentLoop.Profile = .worker, makeTools: @escaping (String) -> AgentTools?,
         saveNote: @escaping (String, String) -> String, openNote: @escaping (String) -> Void = { _ in },
         report: @escaping (String) -> Void, spend: AgentSpend = AgentSpend(), store: UserDefaults = .standard) {
        self.profile = profile
        self.store = store
        if let data = store.data(forKey: Self.historyKey), let saved = try? JSONDecoder().decode([AgentJobView].self, from: data) {
            history = Array(saved.prefix(Self.historySize))
        }
        self.makeTools = makeTools
        self.saveNote = saveNote
        self.openNote = openNote
        self.report = report
        self.spend = spend
    }

    var running: Int { jobs.filter { $0.state == .working || $0.state == .waiting }.count }
    var limitsLine: String {
        "Limits: \(Int(profile.timeLimit / 60)) min" + (profile.budgetUSD.map { String(format: ", $%.2f", $0) } ?? "") + "."
    }

    /// Starts a job, or queues it. The line goes back to whoever asked (the quick loop, the card).
    @discardableResult
    func start(_ task: String) -> String {
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty else { return "Give the agent a task." }
        // Each running agent may still spend up to its own cap: count that, so the day's total never passes the limit.
        let reserve = Double(running + 1) * (profile.budgetUSD ?? 0)
        guard spend.today + reserve <= Self.dailyCapUSD + 0.0001 else {
            return String(format: "The agents can spend $%.2f a day, and the rest of today's money is taken. Try again tomorrow, or stop a running agent first.", Self.dailyCapUSD)
        }
        guard jobs.filter({ $0.state == .queued }).count < Self.maxQueue else {
            return "\(Self.maxQueue) agent tasks wait already. Nothing was added."
        }
        let job = AgentJobView(id: UUID(), name: Self.name(for: task), task: task, state: .queued, step: "Waiting for a free agent",
                               started: nil, ended: nil, tokens: 0, costUSD: nil, resultNote: nil)
        jobs.append(job)
        if running < Self.size {
            launch(job.id)
            return "Agent “\(job.name)” started. \(limitsLine)"
        }
        return "Agent “\(job.name)” waits: \(Self.size) agents are busy."
    }

    /// Stop: a working job ends now (its loop stops); a queued one leaves the queue.
    func stop(_ id: UUID) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        if jobs[i].state == .queued {
            var j = jobs.remove(at: i)
            j.state = .stopped
            j.step = "Stopped before it started"
            j.ended = Date()
            remember(j)
        } else {
            loops[id]?.stop()
        }
    }

    func stopAll() { jobs.map(\.id).forEach(stop) }

    /// Opens the note with the result of an ended job.
    func openResult(_ id: UUID) {
        guard let note = (history + jobs).first(where: { $0.id == id })?.resultNote else { return }
        openNote(note)
    }

    private func update(_ id: UUID, _ change: (inout AgentJobView) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
    }

    private func launch(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        guard let tools = makeTools(job.name) else {
            finish(id, state: .failed, line: "Merlin's tools aren't ready, so the agent didn't start.")
            return
        }
        tools.saveNote = { [weak self] note, text in
            let line = self?.saveNote(note, text) ?? "Notes aren't ready"
            DispatchQueue.main.async { self?.wroteNote[id] = note }
            return line
        }
        tools.startAgent = nil // an agent doesn't start agents
        tools.onStep = { [weak self] line in DispatchQueue.main.async { self?.update(id) { $0.step = line } } }
        tools.onAsk = { [weak self] asking in
            DispatchQueue.main.async { self?.update(id) { $0.state = asking ? .waiting : .working } }
        }
        let loop = AgentLoop()
        loops[id] = loop
        loop.onProgress = { [weak self] now, tokens in
            self?.update(id) {
                if let now { $0.step = now }
                $0.tokens = tokens
            }
        }
        update(id) {
            $0.state = .working
            $0.step = "Starting"
            $0.started = Date()
        }
        loop.run(job.task, tools: tools, profile: profile) { [weak self] outcome in
            guard let self else { return }
            let cost = loop.lastCostUSD
            self.spend.add(cost ?? 0)
            self.update(id) {
                $0.costUSD = cost
                $0.tokens = loop.lastTokens
            }
            switch outcome {
            case .done(let text):
                let stopped = text.hasPrefix("Stopped:")
                if let note = self.wroteNote[id] {
                    self.finish(id, state: stopped ? .stopped : .done, line: stopped ? text : "Wrote in the note \(note)", note: note)
                } else if stopped && text.count < 160 {
                    self.finish(id, state: .stopped, line: text)
                } else {
                    let note = Self.noteName(job.task)
                    _ = self.saveNote(note, Self.noteBody(task: job.task, result: text, cost: cost.map { String(format: "$%.2f", $0) } ?? "cost unknown"))
                    self.finish(id, state: stopped ? .stopped : .done, line: Self.firstLine(text), note: note)
                }
            case .question:
                self.finish(id, state: .failed, line: "It didn't read that as a task.")
            case .failed(let line):
                self.finish(id, state: .failed, line: line)
            }
        }
    }

    private func finish(_ id: UUID, state: AgentJobView.State, line: String, note: String? = nil) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        var j = jobs.remove(at: i)
        j.state = state
        j.step = line.hasPrefix("Stopped: ") ? String(line.dropFirst(9)).capitalizedFirst : line
        j.ended = Date()
        j.resultNote = note
        loops[id] = nil
        wroteNote[id] = nil
        remember(j)
        let verb = state == .done ? "done" : (state == .stopped ? "stopped" : "failed")
        report("Agent “\(j.name)” \(verb): \(j.step)" + (j.costUSD.map { String(format: " ($%.2f)", $0) } ?? ""))
        if let next = jobs.first(where: { $0.state == .queued }), running < Self.size { launch(next.id) }
    }

    private func remember(_ j: AgentJobView) {
        history.insert(j, at: 0)
        if history.count > Self.historySize { history.removeLast(history.count - Self.historySize) }
        if let data = try? JSONEncoder().encode(history) { store.set(data, forKey: Self.historyKey) }
    }

    // MARK: Words

    private static let small: Set<String> = ["a", "an", "the", "to", "of", "on", "in", "for", "and", "my", "me", "find", "please",
                                             "can", "you", "some", "about", "it", "them", "put", "with", "research", "look", "up"]

    /// Three words that name the task ("find five sources on price ceilings" → "Five sources price").
    static func name(for task: String) -> String {
        let words = task.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let picked = words.filter { !small.contains($0.lowercased()) }.prefix(3)
        let name = (picked.isEmpty ? words.prefix(3) : picked).joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    static func noteName(_ task: String) -> String {
        "Agent – " + task.split(separator: " ").prefix(6).joined(separator: " ")
    }

    static func noteBody(task: String, result: String, cost: String) -> String {
        "Task: \(task)\n\n\(result)\n\n(Merlin agent, \(cost))"
    }

    static func firstLine(_ text: String) -> String {
        let line = (text.split(separator: "\n").first.map(String.init) ?? text)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: #"^#+\s*"#, with: "", options: .regularExpression)
        return line.count > 90 ? String(line.prefix(90)) + "…" : line
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

    static func liveOpenNote(_ note: String) {
        _ = CommandRunner.shared?.run(.openNote(note))
    }

    /// One job in each state, for the dock's pictures and tests.
    static var fixtures: [AgentJobView] {
        let now = Date()
        func job(_ name: String, _ state: AgentJobView.State, _ step: String, _ ago: TimeInterval, cost: Double? = nil, note: String? = nil) -> AgentJobView {
            AgentJobView(id: UUID(), name: name, task: name.lowercased(), state: state, step: step, started: state == .queued ? nil : now - ago,
                         ended: [.done, .stopped, .failed].contains(state) ? now - 5 : nil, tokens: 24_000, costUSD: cost, resultNote: note)
        }
        return [job("Price ceilings sources", .working, "Reading: econlib.org", 83),
                job("Email to Tom", .waiting, "Asks: send this email?", 20),
                job("Phone plans compared", .queued, "Waiting for a free agent", 0),
                job("Printing press history", .done, "Wrote in the note History", 312, cost: 0.12, note: "History"),
                job("Laptop prices", .stopped, "Stopped: you stopped it.", 40, cost: 0.03),
                job("Concert tickets", .failed, "It took over 600 s", 600, cost: 0.41)]
    }
}

/// What the agents spent today (UserDefaults), for the daily cap.
final class AgentSpend {
    private let defaults: UserDefaults
    private let key = "agentSpendToday"
    private let calendar = Calendar.current

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var today: Double {
        guard let d = defaults.dictionary(forKey: key), let day = d["day"] as? Double,
              calendar.isDateInToday(Date(timeIntervalSince1970: day)) else { return 0 }
        return d["usd"] as? Double ?? 0
    }

    func add(_ usd: Double) {
        defaults.set(["day": Date().timeIntervalSince1970, "usd": today + usd], forKey: key)
    }
}

// MARK: - The agent rows (top right, until the dock shows the agents)

final class AgentRowPanel {
    private let pool: AgentPool
    private var panel: NSPanel?
    private var watch: AnyCancellable?

    init(pool: AgentPool) {
        self.pool = pool
        watch = pool.$jobs.receive(on: DispatchQueue.main).sink { [weak self] jobs in
            jobs.isEmpty ? self?.hide() : self?.show(rows: jobs.count)
        }
    }

    private func show(rows: Int) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.contentView = NSHostingView(rootView: AgentRowsView(pool: pool))
            panel = p
        }
        guard let p = panel, let screen = NSScreen.main else { return }
        let height = CGFloat(min(rows, AgentPool.size + 1)) * 64 + 8
        let f = screen.visibleFrame
        p.setFrame(NSRect(x: f.maxX - 336, y: f.maxY - height - 12, width: 320, height: height), display: true)
        p.orderFrontRegardless()
    }

    private func hide() { panel?.orderOut(nil) }
}

private struct AgentRowsView: View {
    @ObservedObject var pool: AgentPool

    var body: some View {
        VStack(spacing: 6) {
            ForEach(pool.jobs.prefix(AgentPool.size + 1)) { job in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Agent · " + job.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Text(job.step).font(.system(size: 11)).foregroundStyle(job.state == .waiting ? .orange : .secondary).lineLimit(1)
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in
                            Text(job.state == .queued ? "Waiting" : job.elapsedText(now: ctx.date) + " · " + job.costText)
                                .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Button("Stop") { pool.stop(job.id) }.controlSize(.small)
                }
                .padding(.horizontal, 14)
                .frame(width: 320, height: 58)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            Spacer(minLength: 0)
        }
        .frame(width: 320)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
