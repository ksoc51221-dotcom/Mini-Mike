import AppKit
import SwiftUI

/// `Margin --uishots <dir>`: headless pictures of the main surfaces in light and dark, for design reviews. Nothing is shown on
/// screen (no window is ever ordered in front), no Claude is called, and the library is a throwaway one with made-up chats.
///
/// What cannot be photographed headlessly (and the stand-in used here, in this harness only):
/// - NSVisualEffectView / `.regularMaterial` render blank offscreen, so each frosted surface sits on a flat colour that
///   approximates the blurred material (light 0.96 white, dark 0.20 white). The tint on top is the app's real one.
/// - The real panels' mask, shadow and rim glow are not part of the SwiftUI views, so the harness clips and strokes them.
/// - Animations never run: every picture is the first, static frame.
@MainActor
enum UIShots {
    private struct Mode {
        let name: String
        let scheme: ColorScheme
        let appearance: NSAppearance
        var dark: Bool { scheme == .dark }
    }

    private static let modes = [
        Mode(name: "light", scheme: .light, appearance: NSAppearance(named: .aqua)!),
        Mode(name: "dark", scheme: .dark, appearance: NSAppearance(named: .darkAqua)!),
    ]

    static func run(directory: String) -> Never {
        _ = NSApplication.shared
        Motion.still = true // every animation drawn at its final frame
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        // A throwaway library, set before anything touches Library.shared.
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("margin-uishots-\(UUID().uuidString)")
        Library.overrideDirectory = tmp
        defer { try? FileManager.default.removeItem(at: tmp) }
        var saved = 0
        var failed: [String] = []

        for mode in modes {
            NSApp.appearance = mode.appearance
            func save(_ name: String, _ image: CGImage?) {
                let file = out.appendingPathComponent("\(name)-\(mode.name).png")
                guard let image, (try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: file)) != nil else {
                    failed.append("\(name)-\(mode.name)")
                    return
                }
                saved += 1
            }
            /// SwiftUI view -> PNG, at scale 2, resolved in this mode's appearance, on a neutral desktop-ish backdrop.
            func shot<V: View>(_ name: String, margin: CGFloat = 28, hostedSize: CGSize? = nil, _ view: V) {
                let framed = view
                    .padding(margin)
                    .background(backdrop(mode))
                    .environment(\.colorScheme, mode.scheme)
                var image: CGImage?
                if let hostedSize {
                    var img: CGImage?
                    mode.appearance.performAsCurrentDrawingAppearance {
                        img = hosted(framed, size: CGSize(width: hostedSize.width + margin * 2, height: hostedSize.height + margin * 2), mode)
                    }
                    return save(name, img)
                }
                mode.appearance.performAsCurrentDrawingAppearance {
                    let renderer = ImageRenderer(content: framed)
                    renderer.scale = 2
                    image = renderer.cgImage
                }
                save(name, image)
            }

            // The chat popup, three states.
            shot("chat-1-empty", hostedSize: CGSize(width: AskPanelController.width, height: 200), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.empty)).frame(width: AskPanelController.width, height: 200)))
            AskView.debugPromptsOpen = true
            shot("chat-1b-prompts", hostedSize: CGSize(width: AskPanelController.width, height: 420), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.empty)).frame(width: AskPanelController.width, height: 420)))
            AskView.debugPromptsOpen = false
            shot("chat-2-thinking", hostedSize: CGSize(width: AskPanelController.width, height: 190), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.thinking)).frame(width: AskPanelController.width, height: 190)))
            shot("chat-3-answer", hostedSize: CGSize(width: AskPanelController.width, height: 430), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.answer)).frame(width: AskPanelController.width, height: 430)))

            // The trigger spark, big (4x) and at its real size beside a line of text.
            var spark: CGImage?
            mode.appearance.performAsCurrentDrawingAppearance { spark = TriggerIcon.shotImage() }
            if let spark {
                shot("trigger", margin: 24, HStack(spacing: 24) {
                    Image(decorative: spark, scale: 4).interpolation(.high)
                    Image(decorative: spark, scale: 4).interpolation(.high).resizable().frame(width: 60, height: 60)
                    Image(decorative: spark, scale: 4).interpolation(.high).resizable().frame(width: 30, height: 30)
                })
            } else {
                failed.append("trigger-\(mode.name)")
            }

            // The minimized sidebar: three rows (working, done, error), the folded strip.
            var side: CGImage?
            var strip: CGImage?
            mode.appearance.performAsCurrentDrawingAppearance {
                side = AgentSidebar.shotImage(titles: [
                    ("Closures capture by reference", "Searching the web…", .working, true),
                    ("Supply shift effects", "Done · tap to read", .done, false),
                    ("Stress in замок", "Something went wrong", .failed, false),
                ])
                strip = AgentSidebar.shotImage(titles: [("a", "", .working, false), ("b", "", .done, false), ("c", "", .failed, false)], open: false)
            }
            if let side, let strip {
                shot("sidebar", margin: 24, HStack(alignment: .top, spacing: 24) {
                    Image(decorative: side, scale: 2)
                    Image(decorative: strip, scale: 2)
                })
            } else {
                failed.append("sidebar-\(mode.name)")
            }

            // The voice pill in three states.
            let voice = VoiceController()
            func pill(_ phase: VoiceController.Phase, _ text: String, level: Float = 0) -> some View {
                voice.debugSet(phase, text: text, level: level)
                return panel(mode, radius: 16, VoicePillView(voice: voice))
            }
            shot("voicepill-listening", hostedSize: CGSize(width: 380, height: 64), pill(.listening, "add dinner with Anna to my calendar tomorrow at seven", level: 0.6))
            shot("voicepill-needsmodel", hostedSize: CGSize(width: 380, height: 64), pill(.needsModel("English"), ""))
            shot("voicepill-denied", hostedSize: CGSize(width: 380, height: 64), pill(.micDenied, ""))

            // The library / history window (the Desk, a chat open, a drag in progress, several rows picked, the Bin), with a made-up
            // library. The real one is a hosted view with scroll views and a search field; if ImageRenderer cannot draw part of it,
            // that part shows as a blank placeholder in the picture.
            fillLibrary()
            func window(_ state: LibraryState) -> some View {
                LibraryView(state: state, onAsk: { _, _ in }).frame(width: 1120, height: 700)
            }
            let size = CGSize(width: 1120, height: 700)
            let chats = Library.shared.chats // newest first
            func ref(_ i: Int) -> ItemRef? { chats.indices.contains(i) ? ItemRef(kind: .chat, id: chats[i].id) : nil }
            let desk = LibraryState() // nothing picked, no scope: the Desk
            shot("library-desk", margin: 16, hostedSize: size, window(desk))

            let selected = LibraryState()
            selected.mode = .chats
            selected.selection = ref(0)
            shot("library-selected", margin: 16, hostedSize: size, window(selected))

            // A drag on its way to "Math": the lifted row, the hovered row, and the sector that is glowing.
            let drag = LibraryState()
            drag.mode = .chats
            drag.selection = ref(0)
            drag.debugLift = ref(2)
            drag.dragging = ref(2).map { [$0] } ?? []
            drag.debugHover = ref(4)
            drag.debugDropTarget = "Math"
            shot("library-drag", margin: 16, hostedSize: size, window(drag))

            // Three rows picked with ⌘-click.
            let review = LibraryState()
            review.mode = .review
            review.browsing = true
            review.selection = Review.chats(Library.shared.chats).first.map { ItemRef(kind: .chat, id: $0.chat.id) }
            shot("library-review", margin: 16, hostedSize: size, window(review))

            // Every default sector mark at 16 pt (the size it has in lists), on the surface and on a selected row.
            shot("math-plain-text", margin: 20, VStack(alignment: .leading, spacing: 10) {
                MathLine(text: "Your answer is correct. To write x^(-3/2) in normal form, move the power to the bottom: x^(-3/2) = 1/x^(3/2) = 1/(x√x).")
                MathLine(text: "So dy/dx = 3/(2√x) + 2/(x√x).")
                MathLine(text: "If you want one fraction, write both terms over 2x√x to get (3x + 4)/(2x√x).")
                MathLine(text: "Careful: I/O, 24/7 and 3/4/2026 stay as plain text.")
                MathLine(text: "Differentiate A with respect to r: dA/dr = 40 – (4 + π)r = 0, so r = 40/(4+π) ≈ 5.60 cm.")
                MathLine(text: "The products are x^(1/2)·x^(−1/2) = 1 and −1·x^(−1/2) = −x^(−1/2). Leaving **x^(1/2) – x^(−1/2).**")
            }.frame(width: 560, alignment: .leading).padding(24).background(Theme.canvas.color))

            shot("tick-preview", margin: 20, HStack(spacing: 28) {
                MarginDoneBadge(on: false, size: 56)
                MarginDoneBadge(on: true, size: 56)
                MarginDoneBadge(on: true, size: 56, ink: Theme.accent.color, mark: Theme.onAccent.color)
                MarginDoneBadge(on: true, size: 16)
                Glyph(kind: .check, size: 48, color: Theme.ink.color)
            }.padding(24).background(Theme.surface.color))

            shot("sector-glyphs-16", margin: 16, VStack(spacing: 10) {
                ForEach([false, true], id: \.self) { sel in
                    HStack(spacing: 14) {
                        ForEach(GlyphKind.sectorDefaults, id: \.self) { Glyph(kind: $0, size: 16, color: Theme.ink.color) }
                    }
                    .padding(12).background(sel ? Theme.surfaceSelected.color : Theme.surface.color)
                }
            })

            // Select mode: the new tick on three rows.
            let selecting = LibraryState()
            selecting.mode = .chats
            selecting.selection = ref(0)
            selecting.selecting = true
            selecting.picked = Set([ref(1), ref(3)].compactMap { $0 })
            shot("library-select-tick", margin: 16, hostedSize: size, window(selecting))

            // The Assistant's card beside the sidebar.
            LibraryView.debugAssistantOpen = true
            shot("library-assistant", margin: 16, hostedSize: size, window(selected))
            LibraryView.debugAssistantOpen = false

            let multi = LibraryState()
            multi.mode = .chats
            multi.selection = ref(0)
            multi.multi = Set([ref(0), ref(1), ref(3)].compactMap { $0 })
            shot("library-multi", margin: 16, hostedSize: size, window(multi))

            let bin = LibraryState()
            bin.mode = .bin
            bin.selection = Library.shared.binned.first.map { ItemRef(kind: $0.kind, id: $0.id) }
            shot("library-bin", margin: 16, hostedSize: size, window(bin))

            // A row under the pointer (next to the picked one): background, active glyph, the ↵ hint.
            let hover = LibraryState()
            hover.mode = .chats
            hover.selection = ref(0)
            hover.debugHover = ref(3)
            shot("library-hover", margin: 16, hostedSize: size, window(hover))

            // A sector open (its glyph in the list header), with the first row picked.
            let sectorOpen = LibraryState()
            sectorOpen.mode = .chats
            sectorOpen.sector = "Math"
            sectorOpen.browsing = true
            sectorOpen.selection = Library.shared.chats.first { $0.sector == "Math" }.map { ItemRef(kind: .chat, id: $0.id) }
            shot("library-sector", margin: 16, hostedSize: size, window(sectorOpen))

            // The Bin with nothing in it.
            let keep = Library.shared.binned
            Library.shared.emptyBin()
            let binEmpty = LibraryState()
            binEmpty.mode = .bin
            shot("library-bin-empty", margin: 16, hostedSize: size, window(binEmpty))
            for item in keep { Library.shared.keepInBin(item) }

            // A search that finds nothing.
            let none = LibraryState()
            none.mode = .chats
            none.browsing = true
            none.query = "zzqx"
            shot("library-search-empty", margin: 16, hostedSize: size, window(none))

            // The sector editor's glyph picker (a throwaway store; nothing real is touched).
            let editorDir = tmp.appendingPathComponent("sector-editor")
            let editorStore = SectorStore(directory: editorDir, library: Library.shared)
            if let math = editorStore.sector(named: "Math") {
                shot("sector-glyph-picker", margin: 16, hostedSize: CGSize(width: 580, height: 900),
                     SectorEditorView(store: editorStore, expanded: math.id).frame(width: 580, height: 900))
            }
        }

        print("UISHOTS saved \(saved) pictures to \(directory)")
        if !failed.isEmpty { print("UISHOTS failed: \(failed.joined(separator: ", "))") }
        exit(failed.isEmpty ? 0 : 1)
    }

    // MARK: Harness pieces

    /// Real AppKit controls (TextField, ScrollView) render as "no entry" placeholders in ImageRenderer, so views that have them
    /// are hosted in an NSHostingView that is never put in a window and drawn with cacheDisplay (nothing appears on screen).
    private static func hosted<V: View>(_ view: V, size: CGSize, _ mode: Mode) -> CGImage? {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, mode.scheme))
        host.appearance = mode.appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.settleLayout(passes: 4, interval: 0.12) // let state-driven layout (the thread's height, focus) settle
        return host.snapshotRep()?.cgImage
    }

    /// A neutral desktop stand-in, so frosted and translucent surfaces read.
    private static func backdrop(_ mode: Mode) -> some View {
        LinearGradient(colors: mode.dark ? [Color(white: 0.22), Color(white: 0.30)] : [Color(white: 0.74), Color(white: 0.84)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// A frosted panel photographed without its blur: a flat colour where the material would be, clipped and rimmed like the real one.
    private static func panel<V: View>(_ mode: Mode, radius: CGFloat, _ view: V) -> some View {
        view
            .background(Color(white: mode.dark ? 0.20 : 0.96)) // stand-in for the blurred material behind the tint
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .shadow(color: .black.opacity(mode.dark ? 0.5 : 0.22), radius: 14, y: 6)
    }

    // MARK: Fake chats

    private enum ChatState { case empty, thinking, answer }

    private static func chatModel(_ state: ChatState) -> AskModel {
        let selection = Selection(text: "A closure captures the variables around it by reference, so a later change is visible inside it.",
                                  appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: selection, footnote: "Sonnet · web search on · sees your screen")
        switch state {
        case .empty:
            break
        case .thinking:
            model.turns = [AskModel.Turn(question: "Can you give me an example?")]
            model.isStreaming = true
            model.status = "Searching “swift closures capture list”"
        case .answer:
            model.turns = [AskModel.Turn(
                question: "Can you give me an example?",
                answer: """
                A closure **keeps the variable alive** and sees later changes to it. With `var count = 0`, a closure that prints `count` shows the new value each time you call it.

                - Captured variables are shared, not copied
                - A capture list like `[count]` freezes the value instead
                - Use `[weak self]` to avoid a retain cycle

                Sources: [Swift book](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/closures), [Apple Developer](https://developer.apple.com/documentation/swift)
                """,
                done: true)]
        }
        return model
    }

    // MARK: Fake library

    private static func fillLibrary() {
        let library = Library.shared
        guard library.chats.isEmpty else { return }
        let hour = 3600.0, day = 86_400.0
        // (title, sector, app, hours ago, highlighted text, question, answer)
        let chats: [(String, String, String, Double, String, String, String)] = [
            ("Closures capture by reference", "Computer Science", "Safari", 0.4, "A closure captures the variables around it by reference, so a later change is visible inside it.",
             "Can you give me an example?", "A closure **keeps the variable alive** and sees later changes to it.\n\n- Captured variables are shared\n- `[count]` freezes the value instead\n- Use `[weak self]` to avoid a retain cycle"),
            ("Why a negative a flips the parabola", "Math", "Preview", 1.5, "y = a(x − h)² + k", "Why does a negative a flip it?",
             "Because **a** sets the direction: a negative value reflects the curve over the x-axis, so the vertex becomes a maximum."),
            ("Supply shifts right, price falls", "Economics", "Safari", 3, "supply shifts right", "What happens when supply shifts right?",
             "The equilibrium price falls and the quantity traded rises, as the new curve crosses demand lower down."),
            ("how to do 10 b", "Math", "Preview", 5, "Solve for x: 3x² − 12 = 0", "How do I do 10 b?",
             "Add 12 to both sides, divide by 3, then take both square roots: x = 2 or x = −2."),
            ("Stress in замок: lock or castle", "Language", "Safari", 20, "замок", "How do I pronounce this?",
             "замо́к (lock) is stressed on the second syllable; за́мок (castle) on the first."),
            ("Newton's third law, simply", "Physics", "Safari", 26, "action and reaction", "Simpler?", "Every force has an equal and opposite partner force, acting on the other object."),
            ("Opportunity cost and trade-offs", "Economics", "Notes", 30, "opportunity cost", "Define terms", "The value of the next best thing you give up when you choose."),
            ("What the Treaty of Versailles changed", "History", "Safari", 44, "The Treaty of Versailles was signed on 28 June 1919.", "What did it actually change?",
             "Germany lost territory, accepted blame for the war and agreed to pay reparations; the army was capped at 100,000."),
            ("Binary search off-by-one errors", "Computer Science", "Xcode", 50, "while low <= high", "Why <= and not <?", "With `<=` you still check the last remaining element; with `<` it gets skipped when low == high."),
            ("Elasticity of demand, intuitively", "Economics", "Preview", 72, "price elasticity of demand", "Give me an everyday example",
             "Petrol is inelastic in the short run (you still need to drive); a particular brand of cereal is elastic."),
            ("Why the sky is blue", "Physics", "Safari", 96, "Rayleigh scattering", "Why blue and not violet?",
             "Violet scatters even more, but the sun emits less of it and our eyes are less sensitive to it."),
            ("Derivative of x squared from first principles", "Math", "Preview", 100, "lim h→0 (f(x+h) − f(x)) / h", "Walk me through it",
             "Expand (x+h)², subtract x², divide by h, then let h go to zero. You are left with 2x."),
            ("Passive voice in academic writing", "Language", "Pages", 120, "The experiment was conducted by the team.", "When is passive fine?",
             "When the actor is unknown or unimportant, or the result is what matters. Otherwise prefer the active voice."),
            ("Recursion base cases", "Computer Science", "Xcode", 150, "func fact(_ n: Int) -> Int", "Why does it need a base case?", "Without one the calls never stop and the stack overflows."),
            ("Causes of the French Revolution", "History", "Safari", 24 * 9, "the Estates-General", "What was the Estates-General?",
             "An assembly of the three estates: clergy, nobility and everyone else, last called in 1614 before 1789."),
            ("Conservation of momentum in collisions", "Physics", "Preview", 24 * 12, "p = mv", "Does it hold in inelastic collisions?", "Yes: momentum is conserved, kinetic energy is not."),
            ("Hash tables and collisions", "Computer Science", "Safari", 24 * 15, "load factor", "What is a good load factor?", "Around 0.7 for open addressing; chaining tolerates higher."),
            ("Integration by parts", "Math", "Preview", 24 * 18, "∫ u dv = uv − ∫ v du", "How do I pick u?", "Use LIATE: logarithmic, inverse trig, algebraic, trig, exponential."),
            ("Comparative advantage", "Economics", "Safari", 24 * 22, "comparative advantage", "Is it the same as absolute advantage?", "No: it is about lower opportunity cost, not about being better at everything."),
            ("Aspect in Russian verbs", "Language", "Safari", 24 * 26, "делать / сделать", "Which one do I use?", "Imperfective for the process or habit, perfective for a finished result."),
            ("The Silk Road's decline", "History", "Safari", 24 * 38, "Silk Road", "Why did it decline?", "Sea routes got cheaper and the Mongol peace that protected the overland routes ended."),
            ("Big O of nested loops", "Computer Science", "Safari", 24 * 45, "O(n²)", "Is this always quadratic?", "Only if both loops run to n; if the inner one halves each time it is O(n log n)."),
            ("Entropy and the second law", "Physics", "Preview", 24 * 52, "ΔS ≥ 0", "What does it mean in plain words?", "In an isolated system disorder never decreases on its own."),
            ("Normal distribution and the 68–95–99.7 rule", "Math", "Safari", 24 * 60, "μ ± σ", "Where does 95% come from?", "About two standard deviations either side of the mean hold 95% of the data."),
            ("Inflation and interest rates", "Economics", "Safari", 24 * 70, "central bank", "Why raise rates to fight inflation?", "Higher rates make borrowing dearer, cooling spending and demand."),
        ]
        for (i, c) in chats.enumerated() {
            var chat = ChatRecord(title: c.0, sector: c.1, app: c.2, quote: c.4, turns: [.init(question: c.5, answer: c.6)])
            chat.created = Date().addingTimeInterval(-c.3 * hour - 300)
            chat.updated = Date().addingTimeInterval(-c.3 * hour)
            if i == 0 { chat.quizzes = [QuizResult(title: "Closures", correct: 2, total: 3, missed: [.init(question: "What does a closure capture?", answer: "The variable itself", why: "By reference.")])] }
            if i == 2 { chat.quizzes = [QuizResult(title: "Aspect", correct: 1, total: 2, date: Date().addingTimeInterval(-3 * 86_400), missed: [.init(question: "q", answer: "a", why: "w")])] }
            if i == 3 { // missed once, then retaken all right: not in the review list
                chat.quizzes = [QuizResult(title: "Silk", correct: 1, total: 2, date: Date().addingTimeInterval(-5 * 86_400), missed: [.init(question: "q", answer: "a", why: "w")]),
                                QuizResult(title: "Silk", correct: 2, total: 2, date: Date().addingTimeInterval(-86_400))]
            }
            library.save(chat, touch: false)
        }
        let notes: [(String, String, String, Double, Note.Kind)] = [
            ("Why does a negative a flip it?", "Math", "Negative a reflects the parabola over the x-axis.", 2, .answer),
            ("What is the difference between a stack and a heap?", "Computer Science", "The stack holds call frames and is freed automatically; the heap holds long-lived objects.", 30, .answer),
            ("Which is stressed in замок (lock)?", "Language", "The second syllable: замо́к.", 5, .missed),
            ("When does the second derivative test fail?", "Math", "When f″(x) = 0 it tells you nothing; check the sign change of f′.", 28, .missed),
            ("Define marginal cost", "Economics", "The extra cost of producing one more unit.", 80, .answer),
        ]
        for n in notes {
            var note = Note(title: n.0, sector: n.1, app: "Safari", quote: "", question: n.0, body: n.2)
            note.kind = n.4
            note.created = Date().addingTimeInterval(-n.3 * hour)
            library.add(note)
        }
        let shots: [(String, String, String, Double)] = [
            ("Pricing page, three tiers", "Economics", "Safari", 1), ("Xcode build error, missing module", "Computer Science", "Xcode", 6),
            ("Lecture slide: Fourier series", "Math", "Preview", 30), ("Grocery list in Notes", "Other", "Notes", 52),
        ]
        for s in shots {
            var shot = ScreenshotRecord(created: Date().addingTimeInterval(-s.3 * hour), title: s.0)
            shot.sector = s.1; shot.app = s.2; shot.text = s.0
            library.add(shot)
        }
        // The Bin: a few things deleted over the last month.
        let binned: [(String, String, Double)] = [
            ("Untitled scratch about regex", "Computer Science", 0.2), ("Tax brackets, explained", "Economics", 2),
            ("lorem ipsum test", "Other", 9), ("Mitosis versus meiosis", "Physics", 16), ("Kanji stroke order", "Language", 27),
        ]
        for b in binned {
            let chat = ChatRecord(title: b.0, sector: b.1, app: "Safari", quote: b.0, turns: [.init(question: "Explain", answer: "A short explanation of \(b.0.lowercased()).")])
            library.keepInBin(BinItem(chat: chat, deleted: Date().addingTimeInterval(-b.2 * day)))
        }
    }
}
