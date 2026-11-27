import AppKit
import Combine
import SwiftUI

// Merlin agents on the dock (2026-11-27, round nine): the centre piece next to the record (the record stays). Up to 3
// small agent orbs sit on an arc just outside the disc, above the record; a "+" orb starts a new one. A click opens the Agents
// card: a task field, the running jobs (step, time, cost, Stop) and the last results ("Open note").
// The jobs come from `AgentPool` (the Merlin assistant session's API); the dock only shows them and calls start/stop.

/// What the dock needs from the agents (`AgentPool` in the app; a fixture in the tests and pictures).
protocol DockAgentSource: AnyObject {
    var agentJobs: [AgentJobView] { get }
    var agentHistory: [AgentJobView] { get }
    var agentChanges: AnyPublisher<Void, Never> { get }
    func startAgent(_ task: String) -> String
    func stopAgent(_ id: UUID)
    func openAgentResult(_ id: UUID)
}

extension AgentPool: DockAgentSource {
    var agentJobs: [AgentJobView] { jobs }
    var agentHistory: [AgentJobView] { history }
    var agentChanges: AnyPublisher<Void, Never> { objectWillChange.map { _ in () }.eraseToAnyPublisher() }
    func startAgent(_ task: String) -> String { start(task) }
    func stopAgent(_ id: UUID) { stop(id) }
    func openAgentResult(_ id: UUID) { openResult(id) }
}

/// Jobs in memory: the tests and the pictures (never a real agent).
final class FixtureDockAgents: DockAgentSource {
    @Published var jobs: [AgentJobView]
    @Published var history: [AgentJobView]
    private(set) var started: [String] = []
    private(set) var stopped: [UUID] = []
    private(set) var opened: [UUID] = []

    init(jobs: [AgentJobView] = [], history: [AgentJobView] = []) { self.jobs = jobs; self.history = history }

    /// `AgentPool.fixtures` split the way the pool keeps them: the active ones in `jobs`, the ended ones in `history`.
    static func sample() -> FixtureDockAgents {
        let all = AgentPool.fixtures
        return FixtureDockAgents(jobs: all.filter(\.isActive), history: all.filter { !$0.isActive })
    }

    var agentJobs: [AgentJobView] { jobs }
    var agentHistory: [AgentJobView] { history }
    var agentChanges: AnyPublisher<Void, Never> {
        $jobs.map { _ in () }.merge(with: $history.map { _ in () }).dropFirst(2).eraseToAnyPublisher()
    }
    func startAgent(_ task: String) -> String { started.append(task); return "Agent “\(task)” started." }
    func stopAgent(_ id: UUID) { stopped.append(id) }
    func openAgentResult(_ id: UUID) { opened.append(id) }
}

enum DockAgents {
    /// The app's pool (nil in the tests and pictures, which set a fixture themselves).
    static func live() -> DockAgentSource? {
        let args = CommandLine.arguments
        guard !["--unittest", "--uishots", "--settingsshots", "--edgeglasscheck"].contains(where: { args.contains($0) }) else { return nil }
        return (NSApp.delegate as? AppDelegate)?.agents
    }

    /// The orbs on the disc: up to 3, the working and waiting jobs first, then the queued ones, then a job that ended in
    /// the last 10 s (it shows its check or its grey mark for that long).
    static func orbs(jobs: [AgentJobView], history: [AgentJobView], now: Date = Date()) -> [AgentJobView] {
        let rank: (AgentJobView) -> Int = { $0.state == .working || $0.state == .waiting ? 0 : 1 }
        var out = Array(jobs.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
            .map(\.element).prefix(EdgePanelLayout.agentOrbSlots))
        for h in history where out.count < EdgePanelLayout.agentOrbSlots {
            if let e = h.ended, now.timeIntervalSince(e) < 10 { out.append(h) }
        }
        return out
    }
}

extension EdgePanelLayout {
    /// The agent orbs: on an arc of this radius about the disc's centre, just outside the disc (between it and the app
    /// orbit), above the record by the screen edge; clear of Chats, the orbit at any turn and the screen edge.
    static let agentOrbRadius: CGFloat = 165
    static let agentOrbSize: CGFloat = 24
    static let agentOrbSlots = 3
    /// Degrees up from the disc's left horizontal; the "+" takes the first free place.
    static let agentOrbAngles: [CGFloat] = [85, 72.5, 60]
    /// Place `i` (0...2), from the dock's top-left (y down).
    static func agentOrbCentre(_ i: Int) -> CGPoint {
        let a = agentOrbAngles[min(max(i, 0), agentOrbAngles.count - 1)] * .pi / 180
        return CGPoint(x: dockSize.width - agentOrbRadius * cos(a), y: dockSize.height / 2 - agentOrbRadius * sin(a))
    }
    /// The Agents card: as tall as the add/remove card.
    static var agentsSize: CGSize { CGSize(width: listWidth, height: appsSize.height) }
}

// MARK: - The orbs on the disc

/// The agent orbs and the "+" orb (hidden while the disc's search is open). A click opens the Agents card.
struct EdgeAgentOrbs: View {
    @ObservedObject var model: EdgePanelModel

    var body: some View {
        let orbs = model.agentOrbs
        let p = model.palette
        ZStack(alignment: .topLeading) {
            ForEach(Array(orbs.enumerated()), id: \.element.id) { i, job in
                let c = EdgePanelLayout.agentOrbCentre(i)
                EdgeAgentOrb(state: job.state, palette: p, help: "\(job.name): \(job.step)") { model.tapAgents() }
                    .position(x: c.x, y: c.y)
                    .transition(.opacity.combined(with: .scale(scale: 0.6)))
            }
            if orbs.count < EdgePanelLayout.agentOrbSlots {
                let c = EdgePanelLayout.agentOrbCentre(orbs.count)
                EdgeAgentOrb(state: nil, palette: p, help: "Ask an agent") { model.tapAgents() }
                    .position(x: c.x, y: c.y)
            }
        }
        .animation(Motion.still || Motion.reduceMotion ? nil : Motion.edgeState, value: orbs.map(\.id))
    }
}

/// One orb. nil: the "+" (no job). Working: the accent core breathes; waiting (a yes/no dialog is open): an amber
/// pulse; queued: a dim ring; done: a check; stopped or failed: grey.
private struct EdgeAgentOrb: View {
    let state: AgentJobView.State?
    let palette: DockPalette
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        let size = EdgePanelLayout.agentOrbSize
        let moving = !Motion.still && !Motion.reduceMotion && (state == .working || state == .waiting)
        Button(action: action) {
            ZStack {
                Circle().fill(palette.baseDarkColor.opacity(0.88))
                Circle().strokeBorder(ring, lineWidth: 1)
                core
                    .scaleEffect(moving && pulse ? 1.18 : 1)
                    .opacity(moving && pulse ? 0.75 : 1)
            }
            .frame(width: size, height: size)
            .scaleEffect(hovering ? 1.12 : 1)
            .contentShape(Circle())
        }
        .buttonStyle(EdgePressStyle(scale: 0.92))
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .animation(moving ? .easeInOut(duration: state == .waiting ? 0.6 : 1.1).repeatForever(autoreverses: true) : nil, value: pulse)
        .onAppear { if moving { pulse = true } }
        .onChange(of: moving) { _, on in pulse = on }
        .edgeHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }

    private var ring: Color {
        switch state {
        case .working?: return palette.accentColor.opacity(0.7)
        case .waiting?: return Self.amber.opacity(0.8)
        default: return palette.rimTintColor.opacity(0.3)
        }
    }

    @ViewBuilder private var core: some View {
        switch state {
        case nil:
            Image(systemName: "plus").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary).opacity(0.8)
        case .working?:
            Circle().fill(RadialGradient(colors: [palette.accentColor, palette.accentColor.opacity(0.35)],
                                         center: .center, startRadius: 0, endRadius: 7))
                .frame(width: 12, height: 12)
        case .waiting?:
            Circle().fill(Self.amber).frame(width: 10, height: 10)
        case .queued?:
            Circle().strokeBorder(palette.accentColor.opacity(0.5), lineWidth: 1.5).frame(width: 10, height: 10)
        case .done?:
            Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(palette.accentColor)
        case .stopped?:
            Image(systemName: "stop.fill").font(.system(size: 7, weight: .bold)).foregroundStyle(.secondary)
        case .failed?:
            Image(systemName: "exclamationmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
        }
    }
}

// MARK: - The Agents card

/// The task field, the running jobs and the last results.
struct EdgeAgentsCard: View {
    @ObservedObject var model: EdgePanelModel

    var body: some View {
        let p = model.palette
        let jobs = model.agentJobs, history = model.agentHistory
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Agents").font(.geist(13, .semibold)).foregroundStyle(.primary)
                Spacer()
                Text(jobs.isEmpty ? "None running" : "\(jobs.count) running").font(.geist(11)).foregroundStyle(.secondary)
            }
            .frame(height: 20)
            EdgeAgentTaskField(model: model, palette: p).frame(height: 32)
            if let line = model.agentLine {
                Text(line).font(.geist(11)).foregroundStyle(.secondary).lineLimit(2)
            }
            let content = VStack(alignment: .leading, spacing: 4) {
                if jobs.isEmpty && history.isEmpty {
                    EdgeQuietLine(text: "Type a task. An agent works on it in the background.")
                }
                ForEach(jobs) { job in EdgeAgentRow(job: job, palette: p, model: model) }
                if !history.isEmpty {
                    Text("Recent").font(.geist(11, .medium)).foregroundStyle(.secondary).padding(.top, 6).padding(.leading, 4)
                    ForEach(history.prefix(AgentPool.historySize)) { job in EdgeAgentRow(job: job, palette: p, model: model) }
                }
            }
            if Motion.still {
                content.frame(maxHeight: .infinity, alignment: .top).clipped()
            } else {
                ScrollView(.vertical, showsIndicators: false) { content }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// "Ask an agent…": takes the keyboard as the card opens (or on a click); Return starts the task; Esc is the controller's.
private struct EdgeAgentTaskField: View {
    @ObservedObject var model: EdgePanelModel
    let palette: DockPalette
    @FocusState private var focused: Bool

    private static let prompt = "Ask an agent…"

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            if Motion.still || !model.agentTaskActive {
                Text(model.agentTask.isEmpty ? Self.prompt : model.agentTask)
                    .foregroundStyle(model.agentTask.isEmpty ? HierarchicalShapeStyle.secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField("", text: $model.agentTask, prompt: Text(Self.prompt).foregroundStyle(.secondary))
                    .textFieldStyle(.plain)
                    .foregroundStyle(.primary)
                    .focused($focused)
                    .onSubmit { model.submitAgentTask() }
                    .accessibilityLabel("Ask an agent")
                    .onAppear { DispatchQueue.main.async { focused = true } }
            }
        }
        .font(.geist(12, .medium))
        .lineLimit(1)
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .edgeFieldWell(palette, shadow: false)
        .overlay(Capsule().strokeBorder(model.agentTaskActive ? palette.accentColor.opacity(0.6) : palette.rimTintColor.opacity(0.3),
                                        lineWidth: 1))
        .overlay {
            if !model.agentTaskActive && !Motion.still {
                Capsule().fill(Color.clear).contentShape(Capsule()).onTapGesture { model.activateAgentTask() }
                    .accessibilityElement()
                    .accessibilityLabel("Ask an agent")
                    .accessibilityAddTraits(.isButton)
            }
        }
    }
}

/// A job: its state mark, name and step; a running one shows time, cost and Stop; an ended one with a note shows
/// "Open note".
private struct EdgeAgentRow: View {
    let job: AgentJobView
    let palette: DockPalette
    @ObservedObject var model: EdgePanelModel

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        HStack(spacing: 8) {
            EdgeAgentOrb(state: job.state, palette: palette, help: job.name) {}
                .allowsHitTesting(false)
            VStack(alignment: .leading, spacing: 1) {
                Text(job.name).font(.geist(12, .medium)).foregroundStyle(.primary)
                Text(job.step).font(.geist(11)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Spacer(minLength: 4)
            if job.isActive {
                VStack(alignment: .trailing, spacing: 1) {
                    if Motion.still || job.started == nil {
                        Text(job.elapsedText()).monospacedDigit()
                    } else {
                        TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(job.elapsedText(now: ctx.date)).monospacedDigit() }
                    }
                    Text(job.costText)
                }
                .font(.geist(10)).foregroundStyle(.tertiary)
                Button { model.stopAgent(job.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(palette.rimTintColor.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(EdgePressStyle(scale: 0.9))
                .help("Stop \(job.name)")
                .accessibilityLabel("Stop \(job.name)")
            } else if job.resultNote != nil {
                Button("Open note") { model.openAgentResult(job.id) }
                    .buttonStyle(.plain)
                    .font(.geist(11, .medium))
                    .foregroundStyle(palette.accentColor)
                    .help("Open the result note")
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        .background(shape.fill(palette.restFill))
        .overlay(shape.strokeBorder(palette.hairlineColor, lineWidth: 1))
    }
}
