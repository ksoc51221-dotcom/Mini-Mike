import AppKit
import Combine
import SwiftUI

// Merlin agents on the dock (2026-11-27, round nine): the Agents orb, the largest control after the record, sits on the
// rim's middle place (the record stays in the centre); up to 3 small moons beside it show the running agents. A click
// opens the Agents card: a task field, the running jobs (step, time, cost, Stop) and the last results ("Open note").
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
            .map(\.element).prefix(EdgePanelLayout.agentSatelliteSlots))
        for h in history where out.count < EdgePanelLayout.agentSatelliteSlots {
            if let e = h.ended, now.timeIntervalSince(e) < 10 { out.append(h) }
        }
        return out
    }
}

extension EdgePanelLayout {
    /// The satellites: up to 3 small moons close round the Agents orb, on its left (away from the record), so the
    /// running agents show at a glance.
    static let agentSatelliteSize: CGFloat = 14
    static var agentSatelliteRadius: CGFloat { agentHubSize / 2 + 10 + agentSatelliteSize / 2 }
    static let agentSatelliteSlots = 3
    /// Satellite `i` of `count`, from the dock's top-left (y down): 1 straight left, 2 at ±20°, 3 at -40°, 0°, 40°.
    static func agentSatelliteCentre(_ i: Int, of count: Int) -> CGPoint {
        let n = min(max(count, 1), agentSatelliteSlots)
        let spread: CGFloat = 40
        let deg = n == 1 ? 0 : -spread / 2 * CGFloat(n - 1) + spread * CGFloat(min(max(i, 0), n - 1))
        let a = deg * .pi / 180, h = agentHubCentre
        return CGPoint(x: h.x - agentSatelliteRadius * cos(a), y: h.y + agentSatelliteRadius * sin(a))
    }
    /// The Agents card: as tall as the add/remove card.
    static var agentsSize: CGSize { CGSize(width: listWidth, height: appsSize.height) }
}

extension DockAgents {
    /// What the Agents orb shows: waiting (a yes/no dialog is open) beats working (or queued), then a check for 10 s after
    /// a job ended done, else calm. `running`: the working and waiting jobs (the badge, 1 to 3).
    struct Hub: Equatable {
        enum State: Equatable { case idle, working, waiting, done }
        var state: State
        var running: Int
        var doneUntil: Date?
    }

    static func hub(jobs: [AgentJobView], history: [AgentJobView], now: Date = Date()) -> Hub {
        let running = jobs.filter { $0.state == .working || $0.state == .waiting }.count
        if jobs.contains(where: { $0.state == .waiting }) { return Hub(state: .waiting, running: running) }
        if !jobs.isEmpty { return Hub(state: .working, running: running) }
        if let last = history.first, last.state == .done, let e = last.ended, now.timeIntervalSince(e) < 10 {
            return Hub(state: .done, running: 0, doneUntil: e.addingTimeInterval(10))
        }
        return Hub(state: .idle, running: 0)
    }
}

// MARK: - The Agents orb on the rim

/// The Agents orb (the largest control after the record) with its badge, its ring and its satellites. A click on it or
/// on a satellite opens the Agents card. Hidden while the disc's search is open (as the rim buttons are).
struct EdgeAgentHub: View {
    @ObservedObject var model: EdgePanelModel
    @State private var hovering = false

    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        let _ = DockPerf.tick("agentHub")
        let hub = model.agentHub
        let p = model.palette
        let sats = model.agentOrbs
        let c = EdgePanelLayout.agentHubCentre
        let size = EdgePanelLayout.agentHubSize
        // Motion only while the dock shows (a hidden dock draws nothing) and Reduce Motion is off.
        let live = model.shown && !Motion.still && !Motion.reduceMotion
        ZStack(alignment: .topLeading) {
            ForEach(Array(sats.enumerated()), id: \.element.id) { i, job in
                let at = EdgePanelLayout.agentSatelliteCentre(i, of: sats.count)
                EdgeAgentSatellite(job: job, palette: p) { model.tapAgents() }
                    .position(x: at.x, y: at.y)
                    // motion.dev "spring pop": a new agent's moon springs out of the orb; an ended one shrinks back in.
                    .transition(.scale(scale: 0.2, anchor: .center).combined(with: .opacity))
            }
            ZStack {
                EdgeHubRing(state: hub.state, palette: p, size: size, live: live)
                Button { model.tapAgents() } label: {
                    ZStack {
                        Circle().fill(LinearGradient(colors: [p.accentColor, p.accentColor.opacity(0.72)],
                                                     startPoint: .top, endPoint: .bottom))
                        // Plain glass light: a soft top light and a light-to-dark rim (no bend).
                        Circle().fill(LinearGradient(colors: [.white.opacity(0.30), .clear], startPoint: .top, endPoint: .center))
                        Circle().strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .black.opacity(0.25)],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
                        Image(systemName: hub.state == .done ? "checkmark" : "sparkles")
                            .font(.system(size: 21, weight: .semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.symbolEffect(.replace))
                    }
                    .frame(width: size, height: size)
                    .shadow(color: p.accentColor.opacity(0.45), radius: 10, x: 0, y: 3)
                    .scaleEffect(hovering && !Motion.reduceMotion ? 1.06 : 1)
                    .contentShape(Circle())
                }
                .buttonStyle(EdgePressStyle(scale: 0.94))
                if hub.running > 0 {
                    Text("\(hub.running)")
                        .font(.geist(11, .semibold)).monospacedDigit()
                        .foregroundStyle(.white)
                        .frame(width: 19, height: 19)
                        .background(Circle().fill(p.baseDarkColor))
                        .overlay(Circle().strokeBorder(hub.state == .waiting ? Self.amber : p.accentColor, lineWidth: 1.5))
                        .offset(x: size * 0.36, y: -size * 0.36)
                        .transition(.scale.combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: size + 16, height: size + 16)
            .position(x: c.x, y: c.y)
            .edgeHover { hovering = $0 }
            .help(helpText(hub))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(helpText(hub))
            .accessibilityAddTraits(.isButton)
        }
        .animation(Motion.still || Motion.reduceMotion ? nil : Motion.edgePop, value: sats.map(\.id))
        .animation(Motion.still || Motion.reduceMotion ? nil : Motion.edgePop, value: hub.running)
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        // The check goes back to calm 10 s after the job ended (nothing else may redraw the dock then).
        .task(id: hub.doneUntil) {
            guard let until = hub.doneUntil else { return }
            try? await Task.sleep(nanoseconds: UInt64(max(0, until.timeIntervalSinceNow) * 1_000_000_000) + 50_000_000)
            model.objectWillChange.send()
        }
    }

    private func helpText(_ hub: DockAgents.Hub) -> String {
        switch hub.state {
        case .idle: return "Agents: ask an agent"
        case .working: return "Agents: \(hub.running) working"
        case .waiting: return "Agents: one waits for your yes"
        case .done: return "Agents: done"
        }
    }
}

/// Round the Agents orb: working = an arc that turns (a still arc under Reduce Motion); waiting = an amber ring that
/// pulses; idle and done = nothing. It redraws only while it moves.
private struct EdgeHubRing: View {
    let state: DockAgents.Hub.State
    let palette: DockPalette
    let size: CGFloat
    let live: Bool

    var body: some View {
        let d = size + 7
        switch state {
        case .working:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { ctx in
                let turn = live ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4 : 0.1
                ZStack {
                    Circle().stroke(palette.accentColor.opacity(0.18), lineWidth: 3)
                    Circle().trim(from: 0, to: 0.3)
                        .stroke(palette.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360 - 90))
                }
                .frame(width: d, height: d)
            }
            .allowsHitTesting(false)
        case .waiting:
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !live)) { ctx in
                let t = live ? (sin(ctx.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.2) + 1) / 2 : 0.6
                Circle().stroke(EdgeAgentHub.amber.opacity(0.35 + 0.55 * t), lineWidth: 2.5)
                    .frame(width: d + 3 * t, height: d + 3 * t)
            }
            .allowsHitTesting(false)
        case .idle, .done:
            EmptyView()
        }
    }
}

/// A small moon: one agent's state colour. A hover shows its name and step line beside it.
private struct EdgeAgentSatellite: View {
    let job: AgentJobView
    let palette: DockPalette
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let size = EdgePanelLayout.agentSatelliteSize
        Button(action: action) {
            ZStack {
                Circle().fill(palette.baseDarkColor.opacity(0.9))
                Circle().strokeBorder(rim, lineWidth: 1.5)
                core
            }
            .frame(width: size, height: size)
            .scaleEffect(hovering && !Motion.reduceMotion ? 1.25 : 1)
            .contentShape(Circle().inset(by: -4))
        }
        .buttonStyle(EdgePressStyle(scale: 0.9))
        .overlay(alignment: .trailing) {
            if hovering {
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name).font(.geist(11, .semibold)).foregroundStyle(.primary)
                    Text(job.step).font(.geist(10)).foregroundStyle(.secondary)
                }
                .lineLimit(1)
                .frame(maxWidth: 170, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.baseDarkColor.opacity(0.94)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(palette.hairlineColor, lineWidth: 1))
                .fixedSize()
                .offset(x: -(size + 6))
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .zIndex(hovering ? 3 : 0)
        .animation(Motion.still ? nil : Motion.edgeState, value: hovering)
        .edgeHover { hovering = $0 }
        .accessibilityLabel("\(job.name): \(job.step)")
    }

    private var rim: Color {
        switch job.state {
        case .working: return palette.accentColor
        case .waiting: return EdgeAgentHub.amber
        case .queued: return palette.accentColor.opacity(0.7)
        case .done: return palette.accentColor.opacity(0.8)
        case .stopped, .failed: return Color.gray.opacity(0.6)
        }
    }

    @ViewBuilder private var core: some View {
        switch job.state {
        case .working: Circle().fill(palette.accentColor).frame(width: 6, height: 6)
        case .waiting: Circle().fill(EdgeAgentHub.amber).frame(width: 6, height: 6)
        case .queued: EmptyView()
        case .done: Image(systemName: "checkmark").font(.system(size: 6, weight: .heavy)).foregroundStyle(palette.accentColor)
        case .stopped, .failed: Circle().fill(Color.gray.opacity(0.7)).frame(width: 4, height: 4)
        }
    }
}

/// One orb. nil: the "+" (no job). Working: the accent core breathes; waiting (a yes/no dialog is open): an amber
/// pulse; queued: a dim ring; done: a check; stopped or failed: grey.
private struct EdgeAgentOrb: View {
    let state: AgentJobView.State?
    let palette: DockPalette
    let help: String
    /// The dock shows: only then does a working or waiting orb breathe (a hidden dock draws nothing).
    var live = true
    var size: CGFloat = 24
    let action: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    private static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)

    var body: some View {
        let moving = live && !Motion.still && !Motion.reduceMotion && (state == .working || state == .waiting)
        let idle = state == nil && size > 24
        Button(action: action) {
            ZStack {
                Circle().fill(palette.baseDarkColor.opacity(0.88))
                    // The idle orb: a soft accent glow, still (no loop), so it reads as the place to start.
                    .shadow(color: idle ? palette.accentColor.opacity(0.45) : .clear, radius: idle ? 6 : 0)
                Circle().strokeBorder(idle ? palette.accentColor.opacity(0.75) : ring, lineWidth: idle ? 1.5 : 1)
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
        case nil where size > 24:
            Image(systemName: "sparkles").font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.accentColor)
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
            EdgeAgentOrb(state: job.state, palette: palette, help: job.name, live: model.shown) {}
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
