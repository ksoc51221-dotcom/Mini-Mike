import AppKit
import AVFoundation
import SwiftUI

/// Where a spoken (or typed) command goes. Decided here, on this Mac, by rules, so routing costs nothing.
enum CommandCenter {
    enum Route: Equatable {
        /// "Add … to my calendar": understood on this Mac and shown as a card.
        case calendar
        /// A job for a background agent ("tidy my desktop", "find the PDF about…").
        case task(TaskSpec)
        /// "Show my agents", "what are my agents doing?": the agent bar.
        case agents
        /// "Summarize this video", "listen along": the video summarizer.
        case video(VideoIntent)
        /// Anything else is a question for Claude.
        case ask
    }

    /// Asking to see the agents (or the cats) rather than giving one a job: "show my agents", "what are my agents
    /// doing?", "check on my cats", "open the agent bar". A question that just mentions agents stays a question.
    static func wantsAgentBar(_ text: String) -> Bool {
        let t = text.lowercased()
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"\bagent (?:bar|window|menu)\b"#) { return true }
        let mine = #"\b(?:my|our) (?:agents?|cats|background (?:tasks?|jobs?))\b"#
        let theirs = #"\b(?:the|all(?: the)?|all my) (?:agents|cats)\b"#
        let look = #"\b(?:show|open|bring up|pull up|display|see|check(?: on)?|view)\b"#
        if has(look), has(mine) || has(theirs) { return true }
        return has(mine) && has(#"\b(?:what(?:'s| is| are)|how(?:'s| is| are)|are|is)\b"#)
    }

    /// Takes the wake-up words off the front ("Hey Margin, …").
    static func cleaned(_ spoken: String) -> String {
        var s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^\s*(?:(?:hey|hi|okay|ok)[ ,]+)?margin[ ,.:!]*"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^\s*(?:hey|hi|okay|ok)[ ,]+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func route(_ text: String, now: Date = Date()) -> Route {
        if CalendarIntent.looksLikeRequest(text, now: now) { return .calendar }
        if wantsAgentBar(text) { return .agents }
        if let video = VideoIntent.parse(text) { return .video(video) }
        if let spec = TaskRouter.parse(text, strict: true) { return .task(spec) }
        return .ask
    }
}

/// Hold Cmd+Shift+V and talk; let go and Margin acts on it. Add A (⌘⇧V+A) and what you say is a job for an agent.
/// Your voice is turned into text by Apple's speech model on this Mac: the sound is held in memory only while you
/// talk, never saved or sent anywhere. Only the resulting text goes on, and only to Claude if it's a question for Claude.
///
/// It starts listening the instant you press (see `Dictation`): there's no "getting ready".
final class VoiceController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case listening
        /// Apple's English speech model isn't on the Mac yet; the pill asks before downloading.
        case needsModel(String)
        case micDenied
        case message(String)
    }

    @Published var phase: Phase = .idle
    /// What's been heard so far.
    @Published var text = ""
    @Published var level: Float = 0
    /// Talking to the agents rather than to a chat.
    @Published var forAgent = false

    /// A finished command, as text, and whether it's a job for an agent (⌘⇧V+A).
    var onCommand: ((String, Bool) -> Void)?

    private let pill = VoicePill()
    private var dictation: Dictation?
    /// The talk keys are down.
    private var held = false
    private var limit: Timer?
    private var hideWork: DispatchWorkItem?
    /// Longest a single command can be.
    private static let maxSeconds: TimeInterval = 45

    init() { pill.attach(self) }

    var isBusy: Bool { phase != .idle }

    /// Loads the speech model in the background (call once at launch) so the first press is as quick as the rest.
    func warmUp() {
        Task.detached(priority: .utility) { await Dictation.warmUp() }
    }

    // MARK: Hold to talk

    func talkStart(forAgent: Bool = false) {
        guard dictation == nil, !held else { return }
        hideWork?.cancel()
        self.forAgent = forAgent
        held = true
        text = ""
        level = 0
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            listen()
        case .notDetermined: // the very first press: macOS asks once
            phase = .working("Allow the microphone…")
            pill.show()
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if !granted { self.held = false; self.phase = .micDenied }
                    else if self.held { self.listen() }
                    else { self.show("Microphone is on. Hold ⌘⇧V and speak.") }
                }
            }
        default:
            phase = .micDenied
            pill.show()
        }
    }

    /// The pill is up and the microphone is on, all at once.
    private func listen() {
        let d = Dictation()
        dictation = d
        d.onText = { [weak self] words in self?.text = words }
        d.onLevel = { [weak self] value in self?.level = value }
        d.onFailure = { [weak self] error in self?.listeningFailed(error) }
        phase = .listening
        pill.show()
        d.start()
        limit?.invalidate()
        limit = Timer.scheduledTimer(withTimeInterval: Self.maxSeconds, repeats: false) { [weak self] _ in self?.talkEnd() }
    }

    private func listeningFailed(_ error: Error) {
        limit?.invalidate()
        dictation = nil
        held = false
        level = 0
        if case Dictation.Failure.notInstalled = error {
            phase = .needsModel("English")
            pill.show()
        } else {
            show("Couldn't listen: \(error.localizedDescription)")
        }
    }

    /// A pressed while talking (⌘⇧V+A).
    func switchToAgent() {
        guard held else { return }
        forAgent = true
    }

    func talkEnd() {
        guard held else { return }
        held = false
        guard let d = dictation else { return }
        dictation = nil
        limit?.invalidate()
        Task { await finish(d) }
    }

    @MainActor
    private func finish(_ d: Dictation) async {
        phase = .working("Got it…")
        let spoken = (await d.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
        level = 0
        guard !spoken.isEmpty else { return show("Didn't catch that. Hold ⌘⇧V and speak.") }
        text = spoken
        phase = .idle
        pill.hide(after: 0.35)
        onCommand?(spoken, forAgent)
    }

    // MARK: The download prompt

    /// The pill's Download button: this is the consent. Apple's model comes down once, then works offline.
    func downloadModel() {
        phase = .working("Downloading the English speech model… 0%")
        Task { @MainActor in
            do {
                try await Dictation.installModel { [weak self] fraction in
                    self?.phase = .working("Downloading the English speech model… \(Int(fraction * 100))%")
                }
                Task.detached(priority: .utility) { await Dictation.warmUp() }
                show("Ready. Hold ⌘⇧V to talk, let go to send.")
            } catch {
                show("Couldn't download it: \(error.localizedDescription)")
            }
        }
    }

    func dismiss() {
        dictation?.cancel()
        dictation = nil
        held = false
        limit?.invalidate()
        phase = .idle
        pill.hide(after: 0)
    }

    private func show(_ message: String) {
        phase = .message(message)
        pill.show()
        scheduleHide()
    }

    private func scheduleHide() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .message = self.phase else { return }
            self.phase = .idle
            self.pill.hide(after: 0)
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }

    /// For the demo: a state without any audio.
    func debugSet(_ phase: Phase, text: String = "", level: Float = 0) {
        self.phase = phase
        self.text = text
        self.level = level
    }
    var debugPill: VoicePill { pill }
}

// MARK: - The listening pill

final class VoicePill {
    private let panel = FloatingPanel(size: NSSize(width: 380, height: 64), canKey: false)
    private var host: NSHostingView<VoicePillView>?
    private weak var voice: VoiceController?

    func attach(_ voice: VoiceController) {
        self.voice = voice
        let view = NSHostingView(rootView: VoicePillView(voice: voice))
        view.frame = NSRect(x: 0, y: 0, width: 380, height: 64)
        panel.contentView = view
        panel.hasShadow = true
        host = view
    }

    /// Near the mouse, clear of the screen's edges.
    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 28)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let voice = self.voice, voice.phase == .idle else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.18
                self.panel.animator().alphaValue = 0
            }, completionHandler: { if voice.phase == .idle { self.panel.orderOut(nil) } })
        }
    }

    /// Only the Download / Open Settings states have buttons to click.
    func setClickable(_ on: Bool) { panel.ignoresMouseEvents = !on }

    var debugImage: CGImage? {
        guard let host, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)
        return rep.cgImage
    }
}

private let accent = Color(nsColor: Theme.accent)

struct VoicePillView: View {
    @ObservedObject var voice: VoiceController

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                if let sub = subtitle {
                    Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            action
        }
        .padding(.horizontal, 14)
        .frame(width: 380, height: 64)
        .background(RoundedRectangle(cornerRadius: 16).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(nsColor: PanelGlow.color).opacity(0.55), lineWidth: 1))
        .onChange(of: voice.phase) { _, phase in
            switch phase {
            case .needsModel, .micDenied: voice.debugPill.setClickable(true)
            default: voice.debugPill.setClickable(false)
            }
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch voice.phase {
        case .listening where voice.forAgent:
            PixelCatView(coat: 3, mood: .idle, roam: 0, pixels: 3)
                .frame(width: 36, height: 36)
                .scaleEffect(1 + CGFloat(voice.level) * 0.15)
                .animation(.easeOut(duration: 0.09), value: voice.level)
        case .listening:
            ZStack {
                Circle().fill(accent.opacity(0.18 + Double(voice.level) * 0.5)).frame(width: 36, height: 36)
                    .scaleEffect(1 + CGFloat(voice.level) * 0.35)
                    .animation(.easeOut(duration: 0.09), value: voice.level)
                Image(systemName: "mic.fill").foregroundStyle(accent)
            }
        case .working:
            ProgressView().controlSize(.small).frame(width: 36, height: 36)
        case .needsModel:
            Image(systemName: "arrow.down.circle").font(.title2).foregroundStyle(accent).frame(width: 36, height: 36)
        case .micDenied:
            Image(systemName: "mic.slash.fill").font(.title3).foregroundStyle(.red).frame(width: 36, height: 36)
        case .message, .idle:
            Image(systemName: "mic").font(.title3).foregroundStyle(.secondary).frame(width: 36, height: 36)
        }
    }

    private var title: String {
        switch voice.phase {
        case .listening: return voice.text.isEmpty ? (voice.forAgent ? "Tell an agent what to do…" : "Listening…") : voice.text
        case .working(let s): return s
        case .needsModel(let lang): return "Download the \(lang) voice model?"
        case .micDenied: return "Microphone is off for Margin"
        case .message(let m): return m
        case .idle: return ""
        }
    }

    private var subtitle: String? {
        switch voice.phase {
        case .listening:
            return voice.forAgent ? "For an agent · let go of ⌘⇧V to send" : "Let go of ⌘⇧V to send · press A too for an agent"
        case .needsModel: return "One time. Your voice is turned into text on this Mac and never leaves it."
        case .micDenied: return "Allow it in System Settings → Privacy & Security → Microphone."
        default: return nil
        }
    }

    @ViewBuilder
    private var action: some View {
        switch voice.phase {
        case .needsModel:
            Button("Download") { voice.downloadModel() }.buttonStyle(.borderedProminent).tint(accent)
        case .micDenied:
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                voice.dismiss()
            }.buttonStyle(.bordered)
        default:
            EmptyView()
        }
    }
}
