import AppKit
import Combine

/// What a typed or spoken request asks an agent to do.
enum TaskSpec: Equatable, Codable {
    case tidy(URL)
    case study(URL?, hint: String)
    case find(String)
    case batch(BatchKind, [URL])
    /// Anything else you can put in words ("scatter these screenshots"): Claude plans it, you approve it.
    case custom(String)
    /// A job on your online accounts (Gmail, Google Drive and Docs, Teams): always Claude, read-only until you Allow.
    case connected(String, files: [URL])
}

/// Runs the background agents. Up to three at once; more wait their turn. Each is a `BackgroundTask` the sidebar shows.
final class TaskEngine {
    static let shared = TaskEngine()
    static let maxRunning = 3

    private(set) var tasks: [BackgroundTask] = []
    private var bags: [UUID: AnyCancellable] = [:]
    private var waiting: [(BackgroundTask, () -> Void)] = []

    /// Anything about the tasks changed (the sidebar redraws).
    var onChange: (() -> Void)?
    /// A task has something for you (a plan to approve, or it finished): open its card.
    var onAttention: ((BackgroundTask) -> Void)?

    /// Agents actually working (not ones waiting their turn).
    var runningCount: Int { tasks.filter { $0.state == .working && !$0.queued }.count }

    @discardableResult
    func start(_ spec: TaskSpec) -> BackgroundTask? {
        let task: BackgroundTask
        let launch: () -> Void
        switch spec {
        case .tidy(let folder):
            task = BackgroundTask(kind: .tidy, title: "Tidy \(folder.lastPathComponent)")
            let agent = TidyAgent(folder: folder)
            launch = { agent.run(task) }
        case .study(let file, let hint):
            task = BackgroundTask(kind: .study, title: "Study" + (file.map { ": " + $0.deletingPathExtension().lastPathComponent } ?? ""))
            let agent = StudyAgent(file: file, hint: hint)
            launch = { agent.run(task) }
        case .find(let query):
            task = BackgroundTask(kind: .find, title: "Find: " + String(query.prefix(40)))
            let agent = FindAgent(query: query)
            launch = { agent.run(task) }
        case .batch(let kind, let files):
            task = BackgroundTask(kind: .batch, title: kind.title)
            let agent = BatchAgent(kind: kind, files: files)
            launch = { agent.run(task) }
        case .custom(let request):
            task = BackgroundTask(kind: .custom, title: CustomAgent.title(for: request))
            let agent = CustomAgent(request: request)
            launch = { agent.run(task) }
        case .connected(let request, let files):
            task = BackgroundTask(kind: .connected, title: ConnectedAgent.title(for: request))
            let agent = ConnectedAgent(request: request, files: files)
            launch = { agent.run(task) }
        }
        task.spec = spec
        track(task)
        if runningCount > Self.maxRunning {
            task.detail = "Waiting for another task to finish…"
            task.queued = true
            waiting.append((task, launch))
        } else {
            launch()
        }
        return task
    }

    private func track(_ task: BackgroundTask) {
        tasks.append(task)
        var previous = task.state
        bags[task.id] = task.objectWillChange.sink { [weak self, weak task] _ in
            DispatchQueue.main.async {
                guard let self, let task else { return }
                self.onChange?()
                if task.state != previous {
                    previous = task.state
                    if task.state == .needsApproval || task.isFinished { self.onAttention?(task) }
                    if task.isFinished { self.startWaiting() }
                }
            }
        }
        onChange?()
    }

    private func startWaiting() {
        while runningCount < Self.maxRunning, !waiting.isEmpty {
            let (task, launch) = waiting.removeFirst()
            guard task.state == .working else { continue }
            task.queued = false
            launch()
        }
    }

    /// Allow: the agent goes ahead with its plan.
    func approve(_ task: BackgroundTask) {
        guard task.state == .needsApproval, task.canQuickApprove || task.chooser != nil else { return }
        task.onApprove?(task)
    }

    /// Deny: nothing is changed, and the agent stops. It stays listed, saying so.
    func deny(_ task: BackgroundTask) {
        guard task.state == .needsApproval else { return }
        task.cancelRequested = true
        task.onCancel?()
        task.plan = nil
        task.chooser = nil
        task.gate = nil
        task.onApprove = nil
        task.detail = "Denied · nothing was changed"
        task.state = .cancelled
    }

    /// The × on a row: stops the task if it's still going, then takes it off the list. It goes to the Bin, so a slip of
    /// the mouse isn't the end of it.
    func dismiss(_ task: BackgroundTask) {
        let wasFinished = task.isFinished
        if !wasFinished { task.cancelRequested = true; task.onCancel?() }
        waiting.removeAll { $0.0.id == task.id }
        tasks.removeAll { $0.id == task.id }
        bags[task.id] = nil
        keepInBin(task, wasFinished: wasFinished)
        onChange?()
        startWaiting()
    }

    // MARK: The Bin (dismissed agents)

    /// The agents dismissed since Margin started, whole (report, links and Undo included), so putting one back is exact.
    /// After a restart only the saved summary is left.
    private var binnedLive: [UUID: BackgroundTask] = [:]
    /// For tests: what starts an unfinished agent again (so a test never runs a real one).
    var restarter: ((TaskSpec) -> BackgroundTask?)?

    private func keepInBin(_ task: BackgroundTask, wasFinished: Bool) {
        let outcome: BinnedTask.Outcome
        switch task.state {
        case .done: outcome = .done
        case .failed: outcome = .failed
        case .cancelled: outcome = wasFinished ? .cancelled : .unfinished
        case .working, .needsApproval: outcome = .unfinished
        }
        // What a job on your online accounts read isn't written to disk. (It stays in memory until Margin quits.)
        let keep = task.kind != .connected
        var failure = ""
        if case .failed(let message) = task.state { failure = message }
        let headline = keep ? (task.report?.headline ?? (failure.isEmpty ? task.detail : failure))
                            : "Its results come from your online accounts, so they aren't kept."
        let binned = BinnedTask(
            kind: task.kind.rawValue, title: task.title, outcome: outcome, headline: String(headline.prefix(300)),
            lines: keep ? (task.report?.lines ?? []).prefix(40).map { String($0.prefix(300)) } : [],
            links: keep ? (task.report?.links ?? []).prefix(10).map { .init(title: $0.title, url: $0.url.absoluteString) } : [],
            tokens: task.tokens, spec: task.spec, reportKept: keep)
        binnedLive[task.id] = task
        Library.shared.addToBin(BinItem(agent: binned, id: task.id))
    }

    /// Puts a dismissed agent back on the bar. The same task, report and Undo included, if Margin hasn't been quit since;
    /// otherwise a cat showing what it reported. An agent that hadn't finished starts again from what it was asked.
    @discardableResult
    func restore(_ id: UUID) -> BackgroundTask? {
        guard let item = Library.shared.binItem(id), item.kind == .agent, let binned = item.agent else { return nil }
        var restored: BackgroundTask?
        if binned.outcome == .unfinished, let spec = binned.spec {
            if let restarter { restored = restarter(spec) } else { restored = start(spec) }
        } else if let live = binnedLive[id], live.isFinished {
            track(live)
            restored = live
        } else {
            let kind = BackgroundTask.Kind(rawValue: binned.kind) ?? .custom
            let task = BackgroundTask(kind: kind, title: binned.title)
            task.spec = binned.spec
            task.tokens = binned.tokens
            switch binned.outcome {
            case .failed: task.state = .failed(binned.headline)
            case .cancelled, .unfinished: task.state = .cancelled
            case .done: task.state = .done
            }
            task.detail = binned.headline
            if binned.outcome == .done || !binned.lines.isEmpty {
                task.report = TaskReport(headline: binned.headline, lines: binned.lines,
                                         links: binned.links.compactMap { l in URL(string: l.url).map { TaskLink(title: l.title, url: $0) } })
            }
            track(task)
            restored = task
        }
        guard restored != nil else { return nil }
        binnedLive[id] = nil
        Library.shared.forget(agent: id)
        return restored
    }

    /// An agent deleted from the Bin for good: its whole task isn't needed any more.
    func forgetBinned(_ id: UUID) { binnedLive[id] = nil }

    func task(_ id: UUID) -> BackgroundTask? { tasks.first { $0.id == id } }

    /// For --agentbartest: list a hand-made task (in any state) as if an agent were running it.
    func debugTrack(_ task: BackgroundTask) { track(task) }
}

// MARK: - Tidy agent

/// Scans a folder, makes the plan, waits for approval, then carries it out through FileSafety.
final class TidyAgent {
    private let folder: URL
    private var scan = Tidy.Scan()
    private var texts: [URL: String] = [:]
    private var base: [URL: String] = [:]
    private var plan: TaskPlan?

    init(folder: URL) { self.folder = folder }

    func run(_ task: BackgroundTask) {
        task.onCancel = { [weak task] in task?.cancelRequested = true }
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            task.progress("Looking through \(folder.lastPathComponent)…")
            scan = Tidy.scan(folder)
            let shots = scan.items.filter { $0.category == .screenshot }
            if !shots.isEmpty {
                texts = Tidy.readScreenshots(shots, progress: { done, total in
                    task.progress("Reading screenshots: \(done) of \(total)", Double(done) / Double(total))
                }, cancelled: { task.cancelRequested })
            }
            if task.cancelRequested { return DispatchQueue.main.async { task.state = .cancelled; task.detail = "Cancelled" } }
            base = texts.compactMapValues { Tidy.heuristicTitle($0) }
            let plan = Tidy.plan(folder: folder, scan: scan, titles: base, screenshotTexts: texts.count)
            self.plan = plan
            DispatchQueue.main.async {
                if plan.groups.isEmpty {
                    task.finish(TaskReport(headline: plan.headline, lines: plan.notes))
                    return
                }
                task.plan = plan
                task.detail = "Waiting for your OK"
                task.state = .needsApproval
                task.onApprove = { [self] t in self.approve(t) }
            }
        }
    }

    private func approve(_ task: BackgroundTask) {
        guard var chosen = task.plan else { return }
        let folder = self.folder
        task.state = .working
        task.plan = nil
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var tokens = 0
            // With "name by what's in them" on, Claude names the screenshots that have text; the plan is rebuilt with those names.
            if chosen.option("smartNames") {
                let candidates = scan.items.filter { $0.category == .screenshot }.compactMap { i in texts[i.url].map { (i.url, $0) } }
                task.progress("Naming screenshots…", 0)
                let (titles, used) = Tidy.smartNames(candidates, model: .haiku, cancelled: { task.cancelRequested },
                                                     progress: { d, t in task.progress("Naming screenshots: \(d) of \(t)", Double(d) / Double(max(1, t))) })
                tokens = used
                var merged = base
                for (u, t) in titles { merged[u] = t }
                var rebuilt = Tidy.plan(folder: folder, scan: scan, titles: merged, screenshotTexts: texts.count)
                for i in rebuilt.groups.indices {
                    if let old = chosen.groups.first(where: { $0.key == rebuilt.groups[i].key }) { rebuilt.groups[i].enabled = old.enabled }
                }
                chosen = rebuilt
            }
            let ops = chosen.enabledOps
            var ledger = FileSafety.Ledger(title: task.title)
            let outcome = FileSafety.execute(ops, ledger: &ledger, progress: { d, t in
                task.progress("Moving files: \(d) of \(t)", Double(d) / Double(max(1, t)))
            }, cancelled: { task.cancelRequested })
            FileSafety.save(ledger)
            DispatchQueue.main.async {
                task.tokens += tokens
                var lines = chosen.groups.filter(\.enabled).map { "\($0.title.replacingOccurrences(of: "Move ", with: "Moved ").replacingOccurrences(of: "Sort ", with: "Sorted "))" }
                if !outcome.skipped.isEmpty { lines.append("Skipped \(outcome.skipped.count): " + outcome.skipped.prefix(3).map { "\($0.name) (\($0.reason))" }.joined(separator: "; ")) }
                if tokens > 0 { lines.append("Claude used about \(tokens / 1000)k tokens to name screenshots") }
                var headline = "Done: \(outcome.done) change\(outcome.done == 1 ? "" : "s")"
                if outcome.cancelled { headline = "Stopped after \(outcome.done) change\(outcome.done == 1 ? "" : "s")" }
                var ledgerBox = ledger
                task.onUndo = { t in
                    DispatchQueue.global().async {
                        let result = FileSafety.undo(&ledgerBox)
                        FileSafety.save(ledgerBox)
                        DispatchQueue.main.async {
                            t.undone = true
                            t.canUndo = false
                            t.detail = "Undone: put back \(result.restored)" + (result.couldNotRestore.isEmpty ? "" : ", \(result.couldNotRestore.count) couldn't be")
                            t.report = TaskReport(headline: t.detail, lines: result.couldNotRestore.isEmpty ? [] : ["Not restored (moved or deleted since): " + result.couldNotRestore.prefix(5).joined(separator: ", ")],
                                                  links: [TaskLink(title: "Open \(folder.lastPathComponent)", url: folder)])
                        }
                    }
                }
                task.finish(TaskReport(headline: headline, lines: lines, links: [TaskLink(title: "Open \(folder.lastPathComponent)", url: folder)]),
                            canUndo: outcome.done > 0)
            }
        }
    }
}
