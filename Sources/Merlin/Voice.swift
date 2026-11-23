import AppKit
import AVFoundation
import SwiftUI

/// Where a spoken (or typed) command goes. Decided here, on this Mac, by rules, so routing costs nothing.
enum CommandCenter {
    enum Route: Equatable {
        /// "Add … to my calendar": understood on this Mac and shown as a card.
        case calendar
        /// "Summarize this video", "listen along": the video summarizer.
        case video(VideoIntent)
        /// "Open microeconomics note", "show my physics terms" (a sheet with that exact name): opens the sheet.
        case openNote(String)
        /// "Add this to my macro note": the newest answer goes into the sheet.
        case addToNote(String)
        /// "Make a new note called macro terms".
        case newNote(String)
        /// "Show my chats" / "show my notes": the edge panel, pinned.
        case openChats
        case openNotes
        /// Anything else is a question for Claude.
        case ask

        /// One of the commands that act and open no chat (see `NoteCommand`).
        var isNoteCommand: Bool {
            switch self {
            case .openNote, .addToNote, .newNote, .openChats, .openNotes: return true
            case .calendar, .video, .ask: return false
            }
        }
    }

    /// Takes the wake-up words off the front ("Hey Merlin, …"). "Margin" still works: it was the app's old name.
    static func cleaned(_ spoken: String) -> String {
        var s = spoken.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.replacingOccurrences(of: #"^\s*(?:(?:hey|hi|okay|ok)[ ,]+(?:merlin|margin)\b|merlin\b|margin\s*(?:[,.:!]|$))[ ,.:!]*"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^\s*(?:hey|hi|okay|ok)[ ,]+"#, with: "", options: [.regularExpression, .caseInsensitive])
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `sheets`: the names of the sheets (named notes), so "show my physics terms" can open one. Calendar and video come
    /// first, exactly as before; a note command is checked last and only with strict rules (`NoteCommand`).
    static func route(_ text: String, now: Date = Date(), sheets: [String] = []) -> Route {
        if CalendarIntent.looksLikeRequest(text, now: now) { return .calendar }
        if let video = VideoIntent.parse(text) { return .video(video) }
        return NoteCommand.parse(text, sheets: sheets) ?? .ask
    }
}

/// Hold the talk key (Tab + Q unless changed) and talk; let go and Merlin acts on it.
/// Your voice is turned into text by one of two engines (Settings → General → Voice):
/// - "On this Mac" (the default): Apple's speech model. The sound never leaves this Mac.
/// - "Groq Whisper" (only with a saved Groq key): when you let go, the sound of that one press is made into a WAV in
///   memory and sent once to Groq (api.groq.com) to be turned into text. Apple's live words still show while you talk,
///   and are used instead if Groq fails, is slow, or refuses the key.
/// Either way the sound is held in memory only, is never saved to disk, and is dropped once the text is ready.
/// The resulting text goes on, and only to Claude if it's a question for Claude.
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
    /// Which engine made the last text (shown under it for a moment as the orb leaves).
    @Published var engine: VoiceEngine?
    /// The pill is on screen (drives its appear / leave motion).
    @Published var presented = false
    /// A press started (bumped on each press; the orb's ripple ring follows it).
    @Published var pressCount = 0
    /// A finished command, as text.
    var onCommand: ((String) -> Void)?

    /// Where the Groq key is read, how Groq is reached, and which engine is chosen. Tests swap all three.
    var keys: GroqKeyStore = GroqKeys.shared
    var transport: GroqTransport = GroqTranscriber.liveTransport
    var settings: Settings = .shared
    /// The "Groq refused the key" line has been shown this run.
    private var toldBadKey = false
    /// Bumped by every press and by dismiss: a slow Groq answer for an older press is then thrown away.
    private var session = 0

    private let pill = VoicePill()
    private var dictation: Dictation?
    /// The talk keys are down.
    private var held = false
    private var limit: Timer?
    private var hideWork: DispatchWorkItem?
    /// Shown once per run when Groq refuses the key (the on-device text is still used).
    static let groqSilentMessage = "Groq did not answer. Try again."
    static let groqRefusedMessage = "Groq refused the key. Check it in Settings."
    static let badKeyMessage = "Groq key refused. Used this Mac's text."
    /// Longest a single command can be.
    private static let maxSeconds: TimeInterval = 45

    init() { pill.attach(self) }

    var isBusy: Bool { phase != .idle }

    /// Loads the speech model in the background (call once at launch) so the first press is as quick as the rest.
    func warmUp() {
        Task.detached(priority: .utility) { await Dictation.warmUp() }
    }

    // MARK: Hold to talk

    func talkStart() {
        guard dictation == nil, !held else { return }
        hideWork?.cancel()
        held = true
        session += 1
        text = ""
        level = 0
        engine = nil
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
                    else { self.show("Microphone is on. Hold \(KeybindStore.shared.current.chord(.talk).display) and speak.") }
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
        // With Groq chosen and a key saved, a missing Apple model is no reason to stop: record, and let Groq make the text.
        d.recordOnlyIfNoModel = VoiceDecision.usesGroq(choice: settings.voiceEngine, keys: keys)
        phase = .listening
        pressCount += 1
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
            // The model is often already on this Mac and only needs claiming for Merlin: do that without asking.
            // Only when it truly isn't here does the prompt show (that download needs your OK).
            phase = .working("Getting the voice model ready…")
            pill.show()
            let mine = session
            // It normally takes about 15 seconds. If macOS never answers (offline, say), stop waiting and show the prompt.
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
                guard let self, mine == self.session, case .working("Getting the voice model ready…") = self.phase else { return }
                self.phase = .needsModel("English")
                self.pill.show()
            }
            Task { @MainActor in
                let ready = await Dictation.allocateIfOnThisMac()
                guard mine == self.session, case .working = self.phase else { return }
                if ready {
                    Task.detached(priority: .utility) { await Dictation.warmUp() }
                    self.show("Ready. Hold \(KeybindStore.shared.current.chord(.talk).display) to talk, let go to send.")
                } else {
                    self.phase = .needsModel("English")
                    self.pill.show()
                }
            }
        } else {
            show("Couldn't listen: \(error.localizedDescription)")
        }
    }

    func talkEnd() {
        guard held else { return }
        held = false
        guard let d = dictation else { return }
        dictation = nil
        limit?.invalidate()
        let mine = session
        Task { await finish(d, session: mine) }
    }

    /// You let go: Apple's text, then (when chosen and a key is saved) Groq's, which replaces it. Any Groq problem falls
    /// back to Apple's text. A tap shorter than 0.4 s, or one where Apple heard no words, is dropped.
    @MainActor
    private func finish(_ d: Dictation, session mine: Int) async {
        let choice = settings.voiceEngine
        phase = .working(choice == .groq ? "Transcribing…" : "Got it…")
        let spoken = (await d.finish()).trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = d.clip
        d.releaseClip()
        guard mine == session else { return } // a new press, or dismissed, while this one finished
        level = 0
        if !spoken.isEmpty { text = spoken }
        let result = await VoiceDecision.resolve(appleText: spoken, clip: clip, choice: choice, keys: keys, transport: transport)
        guard mine == session else { return } // a slow Groq answer for an older press
        switch result {
        case .discard:
            show("Didn't catch that. Hold \(KeybindStore.shared.current.chord(.talk).display) and speak.")
        case .noAnswer(let badKey):
            show(badKey ? Self.groqRefusedMessage : Self.groqSilentMessage) // no text from anyone: no chat opens
        case let .deliver(final, used, badKey):
            text = final
            engine = used
            if VoiceDecision.shouldTellBadKey(badKey, alreadyTold: toldBadKey) {
                toldBadKey = true
                show(Self.badKeyMessage)
            } else {
                phase = .idle
                pill.hide(after: 0.9) // long enough to read which engine made the text; the chat opens at once
            }
            onCommand?(final)
        }
    }

    // MARK: The download prompt

    /// The pill's Download button: this is the consent to download. Apple's model comes down once, then works offline.
    /// (When the model is already on this Mac, Merlin claims it without this prompt: see `listeningFailed`.)
    func downloadModel() {
        phase = .working("Downloading the English speech model… 0%")
        Task { @MainActor in
            do {
                try await Dictation.installModel { [weak self] fraction in
                    self?.phase = .working("Downloading the English speech model… \(Int(fraction * 100))%")
                }
                Task.detached(priority: .utility) { await Dictation.warmUp() }
                show("Ready. Hold \(KeybindStore.shared.current.chord(.talk).display) to talk, let go to send.")
            } catch {
                show("Couldn't download it: \(error.localizedDescription)")
            }
        }
    }

    /// "Use a Groq key" on the model prompt: Settings → General, where the Groq key field is.
    var onOpenGroqSettings: (() -> Void)? = { LibraryWindow.shared.showSettings(section: .general) }
    func openGroqKeySettings() {
        dismiss()
        onOpenGroqSettings?()
    }

    func dismiss() {
        session += 1
        dictation?.cancel()
        dictation = nil
        held = false
        limit?.invalidate()
        phase = .idle
        pill.hide(after: 0)
    }

    /// One line of result for a command that acted ("Opened Microeconomics terms"). It hides by itself, like any message.
    func say(_ line: String) {
        hideWork?.cancel()
        show(line)
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
        presented = true // the view is visible without `show()` (demo pictures)
    }
    var debugPill: VoicePill { pill }
}

// MARK: - The listening orb

final class VoicePill {
    /// The panel: room for the orb, its rings and ripple, and the caption card under it. Everything outside them is clear.
    static let size = NSSize(width: 320, height: 290)
    private let panel = FloatingPanel(size: VoicePill.size, canKey: false)
    private var host: NSHostingView<ThemedRoot<VoicePillView>>?
    private weak var voice: VoiceController?

    func attach(_ voice: VoiceController) {
        self.voice = voice
        let view = NSHostingView(rootView: ThemedRoot { VoicePillView(voice: voice) })
        view.frame = NSRect(origin: .zero, size: Self.size)
        panel.contentView = view
        panel.hasShadow = false // the orb draws its own glow, the card its own shadow
        panel.ignoresMouseEvents = true
        host = view
    }

    /// Near the mouse, clear of the screen's edges.
    func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        var origin = NSPoint(x: mouse.x - size.width / 2, y: mouse.y + 20)
        origin.x = min(max(origin.x, vf.minX + 8), vf.maxX - size.width - 8)
        origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1 // the view fades and scales itself in
        if !panel.isVisible { panel.orderFrontRegardless() }
        voice?.presented = true
    }

    func hide(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let voice = self.voice, voice.phase == .idle else { return }
            voice.presented = false // the view fades and scales itself out
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                if voice.phase == .idle && !voice.presented { self.panel.orderOut(nil) }
            }
        }
    }

    /// Only the Download / Open Settings states have buttons to click.
    func setClickable(_ on: Bool) { panel.ignoresMouseEvents = !on }

    var debugImage: CGImage? {
        return host?.snapshotRep()?.cgImage
    }
}

private let accent = Theme.accent.color

/// The orb, with one caption line (the words so far, or what's happening) and one small hint line under it.
struct VoicePillView: View {
    @ObservedObject var voice: VoiceController
    @State private var scale: CGFloat = 0.95
    @State private var opacity: Double = 0

    var body: some View {
        VStack(spacing: -14) { // the canvas has room for the ripple; pull the card up under the orb
            VoiceOrb(mood: mood, level: voice.level, pressCount: voice.pressCount)
            card
        }
        .frame(width: VoicePill.size.width, height: VoicePill.size.height, alignment: .bottom)
        .scaleEffect(Motion.still || Motion.reduceMotion ? 1 : scale, anchor: .bottom)
        .opacity(Motion.still ? 1 : opacity)
        .onChange(of: voice.presented) { _, on in
            let reduce = Motion.reduceMotion
            if on { // in: opacity 0 → 1, scale 0.95 → 1, 0.3 s
                withAnimation(reduce ? .easeOut(duration: 0.12) : .easeOut(duration: 0.3)) { scale = 1; opacity = 1 }
            } else { // out: scale → 0.97, opacity → 0
                withAnimation(reduce ? .easeOut(duration: 0.12) : Motion.exit, completionCriteria: .logicallyComplete) {
                    scale = 0.97; opacity = 0
                } completion: {
                    if !voice.presented { scale = 0.95 } // the next appear starts at 0.95 again
                }
            }
        }
        .onChange(of: voice.phase) { _, phase in
            switch phase {
            case .needsModel, .micDenied: voice.debugPill.setClickable(true)
            default: voice.debugPill.setClickable(false)
            }
        }
    }

    private var mood: VoiceOrb.Mood {
        switch voice.phase {
        case .listening: return .listening
        case .working: return .working
        default: return .calm
        }
    }

    private var card: some View {
        VStack(spacing: 3) {
            Text(caption)
                .font(.mUI.weight(.semibold)).foregroundStyle(Theme.ink.color)
                .lineLimit(2).truncationMode(voice.phase == .listening ? .head : .tail).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let hint {
                Text(hint)
                    .font(.mMeta).foregroundStyle(Theme.inkSecondary.color)
                    .lineLimit(2).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action.padding(.top, 5)
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .frame(maxWidth: 296)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            .fill(Motion.still ? AnyShapeStyle(Theme.surface.color) : AnyShapeStyle(.regularMaterial)))
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surfaceTint.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
        .padding(.bottom, 10)
        .opacity(caption.isEmpty ? 0 : 1)
    }

    private var caption: String {
        switch voice.phase {
        case .listening: return voice.text.isEmpty ? "Listening…" : voice.text
        case .working(let s): return s
        case .needsModel(let lang): return "Get the \(lang) voice model?"
        case .micDenied: return "Microphone is off for Merlin"
        case .message(let m): return m
        case .idle: return voice.text // the finished text, for the moment the orb takes to leave
        }
    }

    private var hint: String? {
        switch voice.phase {
        case .listening: return "Let go of \(KeybindStore.shared.current.chord(.talk).display) to send"
        case .needsModel: return "Apple's speech model isn't on this Mac. Download it, or use a Groq key instead."
        case .micDenied: return "Allow it in System Settings → Privacy & Security → Microphone."
        case .idle: return voice.engine?.title
        default: return nil
        }
    }

    @ViewBuilder
    private var action: some View {
        switch voice.phase {
        case .needsModel:
            HStack(spacing: 8) {
                Button("Use a Groq key") { voice.openGroqKeySettings() }.buttonStyle(QuietPillAction())
                Button("Download") { voice.downloadModel() }.buttonStyle(PillAction(fill: accent))
            }
        case .micDenied:
            Button("Open Settings") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                voice.dismiss()
            }.buttonStyle(PillAction(fill: accent))
        default:
            EmptyView()
        }
    }
}

/// The second, quiet choice next to a filled one: text on a hairline outline.
private struct QuietPillAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .medium))
            .foregroundStyle(Theme.ink.color.opacity(configuration.isPressed ? 0.6 : 1))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).strokeBorder(Theme.hairlineStrong.color, lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}

/// A filled accent button for the voice pill. The system's prominent style draws grey here, because the pill's
/// panel never becomes the key window.
private struct PillAction: ButtonStyle {
    let fill: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .semibold))
            .foregroundStyle(Theme.onAccent.color)
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(fill.opacity(configuration.isPressed ? 0.75 : 1)))
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous))
    }
}
