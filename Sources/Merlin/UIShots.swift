import AppKit
import SwiftUI

/// `Merlin --uishots <dir>`: headless pictures of the main surfaces in light and dark, for design reviews. Nothing is shown on
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
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("merlin-uishots-\(UUID().uuidString)")
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
            shot("chat-2-thinking", hostedSize: CGSize(width: AskPanelController.width, height: 190), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.thinking)).frame(width: AskPanelController.width, height: 190)))
            shot("chat-3-answer", hostedSize: CGSize(width: AskPanelController.width, height: 430), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.answer)).frame(width: AskPanelController.width, height: 430)))
            // The header's buttons in full (star, size, close; no bookmark): the 380-wide pictures above crop their right edge.
            shot("chat-3b-header", hostedSize: CGSize(width: 640, height: 150), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: chatModel(.answer)).frame(width: 640, height: 150)))

            // The whiteboard (price ceiling sample): step 1, a middle step, the last step, at the chat's answer width;
            // then the same board inside a chat.
            for (name, step) in [("board-1-first", 0), ("board-2-middle", 2), ("board-3-last", 3)] {
                shot(name, margin: 20, BoardView(source: BoardSpec.priceCeilingSample, initialStep: step)
                    .frame(width: AskPanelController.width - 32))
            }
            // Tables (R1): Merlin's economics terms table at the normal and the wide answer width, half-streamed, with the
            // Copy table button showing, and inside a normal and a wide chat. Hosted, because a ScrollView may be inside.
            let narrow = AskPanelController.width - 32, wide = AskPanelController.width * AskModel.largeScale - 32
            func tableShot(_ name: String, width: CGFloat, height: CGFloat, _ view: some View) {
                shot(name, hostedSize: CGSize(width: width + 32, height: height),
                     panel(mode, radius: AskPanelController.cornerRadius,
                           view.frame(width: width).padding(16).frame(width: width + 32, height: height, alignment: .top)))
            }
            tableShot("table-1-narrow", width: narrow, height: 760, MarkdownText(text: MarkdownTable.economicsSample))
            tableShot("table-2-wide", width: wide, height: 470, MarkdownText(text: MarkdownTable.economicsSample))
            let halfway = MarkdownTable.economicsSample.components(separatedBy: "willing")[0] + "wil"
            tableShot("table-3-streaming", width: narrow, height: 420, MarkdownText(text: halfway, streaming: true))
            if let table = MarkdownTable.blocks(MarkdownTable.economicsSample).compactMap({ if case .table(let t) = $0 { return t } else { return nil } }).first {
                tableShot("table-4-copy", width: wide, height: 450, TableCard(table: table, forceHover: true))
            }
            for (name, large) in [("table-5-chat", false), ("table-6-chat-wide", true)] {
                let model = tableChatModel(large: large)
                shot(name, hostedSize: CGSize(width: model.width, height: large ? 700 : 560),
                     panel(mode, radius: AskPanelController.cornerRadius, AskView(model: model).frame(width: model.width, height: large ? 700 : 560)))
            }
            // R5: the same chat at a size set by hand: wide, and the smallest allowed. The answer area scrolls inside.
            for (name, size) in [("table-7-chat-hand-wide", CGSize(width: 760, height: 520)), ("table-8-chat-smallest", PanelResize.minSize)] {
                let model = tableChatModel(large: false)
                model.isManualSize = true
                shot(name, hostedSize: size,
                     panel(mode, radius: AskPanelController.cornerRadius, AskView(model: model).frame(width: size.width, height: size.height)))
            }
            do {
                let model = boardChatModel()
                model.isManualSize = true
                shot("board-5-chat-hand-wide", hostedSize: CGSize(width: 760, height: 560),
                     panel(mode, radius: AskPanelController.cornerRadius, AskView(model: model).frame(width: 760, height: 560)))
            }
            shot("board-4-chat", hostedSize: CGSize(width: AskPanelController.width, height: 520), panel(mode, radius: AskPanelController.cornerRadius, AskView(model: boardChatModel()).frame(width: AskPanelController.width, height: 520)))
            // The 3D scenes (atom; forces on a block) at the chat's answer width. A live SCNView can't be captured, so
            // with Motion.still the card shows an offscreen SCNRenderer picture of the same scene (orbits at their start).
            for (name, source) in [("scene-1-atom", SceneSpec.atomSample), ("scene-2-forces", SceneSpec.forcesSample)] {
                shot(name, margin: 20, SceneView3D(source: source).frame(width: AskPanelController.width - 32))
            }

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

            // The hidden edge panel (R3), which replaced the Chats sidebar: at rest (only the dot at a screen edge, working
            // and answer ready), the two-choice box (resting and under the pointer), the Chats list, the Notes list.
            shot("edge-1-rest", margin: 24, HStack(spacing: 24) {
                edgeRest(.breathing, "Working", mode)
                edgeRest(.solid, "Answer ready", mode)
                edgeRest(.absent, "Nothing going on", mode)
            })
            // The dock (version 1): emerald with two fixture apps and no music; the Chats and Notes cards; a song playing
            // (the dock takes the cover's colours) with the Spotify card; the add/remove card.
            // Each on a wallpaper-like backdrop, so the glass's contrast over a desktop shows.
            shot("edge-2-box", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(nil), framed: false)))
            shot("edge-3-chats", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.chats), framed: false)))
            shot("edge-4-notes", margin: 0, edgeWall(mode, HStack(alignment: .top, spacing: 24) {
                EdgePanelView(model: edgeModel(.notes), framed: false)
                EdgePanelView(model: edgeModel(.notes, empty: true), framed: false)
            }))
            shot("edge-5-spotify", margin: 0, edgeWall(mode, VStack(alignment: .trailing, spacing: 24) {
                EdgePanelView(model: edgeModel(.spotify, music: true), framed: false)
                EdgePanelView(model: edgeModel(.spotify, spotify: .denied), framed: false)
            }))
            shot("edge-6-apps", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.apps), framed: false)))
            // The whole window as on screen (clipped to it): six apps (eight ring items) and a song playing.
            shot("edge-7-full", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(nil, music: true, apps: 6)).clipped(), pad: 0))
            // Search open with "ca" typed: only Calendar shows, at the ring's middle-left point.
            shot("edge-8-search", margin: 0, edgeWall(mode, EdgePanelView(model: edgeSearchModel("ca")).clipped(), pad: 0))
            // The add/remove card's search with "no" typed (a text stand-in for the field), and a full dock (six apps) on
            // the Available tab: dim Add buttons and the "Remove an app to add another" line.
            shot("edge-9-apps-search", margin: 0, edgeWall(mode, EdgePanelView(model: edgeAppsModel(query: "no"), framed: false)))
            shot("edge-10-apps-full", margin: 0, edgeWall(mode, EdgePanelView(model: edgeAppsModel(apps: 6, filter: .available),
                                                                              framed: false)))
            // The Spotify mini player in the whole window as on screen (clipped to it, so anything outside the window's
            // slack would be cut): a song playing (the fixture song), and Spotify not open (transport off, "Open Spotify").
            shot("edge-11-spotify-mini", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.spotify, music: true)).clipped(), pad: 0))
            shot("edge-12-spotify-closed", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.spotify, spotify: .notRunning)).clipped(), pad: 0))
            // "My songs": "mi" typed (three sample rows, one starred) in the record's place; the star filter on with no
            // saved song (the empty-list line). The query is set on the model (a text stand-in for the field).
            shot("edge-13-songs-list", margin: 0, edgeWall(mode, EdgePanelView(model: edgeSongsModel(query: "mi")).clipped(), pad: 0))
            shot("edge-13b-songs-spotify", margin: 0, edgeWall(mode, EdgePanelView(model: edgeSpotifyHitsModel()).clipped(), pad: 0))
            shot("edge-14-songs-empty", margin: 0, edgeWall(mode, EdgePanelView(model: edgeSongsModel(starred: true, empty: true)).clipped(), pad: 0))

            // The dock taking its colours from generated covers: very bright, grey, blue. The full dock (six apps) with the
            // Spotify mini window open.
            for (name, image) in [("edge-15-cover-bright", EdgeDockFixtures.coverBright()),
                                  ("edge-16-cover-grey", EdgeDockFixtures.coverGrey()),
                                  ("edge-17-cover-blue", EdgeDockFixtures.coverBlue())] {
                shot(name, margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.spotify, music: true, apps: 6, cover: image)).clipped(), pad: 0))
            }
            // The beat strings at their widest: the mini window (and the disc) pinned to a strong kick (level 0.9, bass
            // 0.9, kick 1), one fixed frame from a fixed seed. No tap: the live source is blocked in picture runs.
            let kick = edgeModel(.spotify, music: true)
            kick.spotify.beat.pinned = BeatSample(level: 0.9, bass: 0.9, kick: 1)
            shot("edge-18-strings-kick", margin: 0, edgeWall(mode, EdgePanelView(model: kick).clipped(), pad: 0))

            // Round five, against the Stitch pictures: the whole window, 7 ring items (Chats, Notes, five apps with their
            // real icons). At rest with the fixture song PAUSED (the strings are three still circles); the Spotify card
            // open with the song playing (the disc is empty, the record is in the card); and at rest playing, pinned to a
            // kick (one fixed frame).
            if mode.dark {
                var paused = EdgeDockFixtures.track
                paused.isPlaying = false
                shot("edge-19-stitch-rest", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(nil, music: true,
                    spotify: .track(paused), apps: 5)).clipped(), pad: 0))
                shot("edge-20-stitch-card", margin: 0, edgeWall(mode, EdgePanelView(model: edgeModel(.spotify, music: true,
                    apps: 5)).clipped(), pad: 0))
                let restKick = edgeModel(nil, music: true, apps: 5)
                restKick.spotify.beat.pinned = BeatSample(level: 0.6, bass: 0.6, kick: 1)
                shot("edge-21-stitch-rest-kick", margin: 0, edgeWall(mode, EdgePanelView(model: restKick).clipped(), pad: 0))
            }

            // The Assistant's button up close: in the Library's sidebar (resting, open, working) and in the settings list.
            shot("assistant-button", margin: 20, HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 10) {
                    AssistantOrbRow(action: {})
                    AssistantOrbRow(open: true, action: {})
                    AssistantOrbRow(busy: true, action: {})
                }
                .padding(.horizontal, 10).padding(.vertical, 12).frame(width: 224).background(Ink.side)
                VStack(spacing: 10) {
                    AssistantOrbRow(action: {})
                    AssistantOrbRow(open: true, action: {})
                }
                .padding(.horizontal, 12).padding(.vertical, 12).frame(width: 192).background(Theme.surface.color)
            })

            // The voice pill in three states.
            let voice = VoiceController()
            // The voice orb: its panel is clear, so it's drawn straight on the backdrop (no frosted panel behind it).
            func orb(_ phase: VoiceController.Phase, _ text: String, level: Float = 0, engine: VoiceEngine? = nil) -> some View {
                voice.debugSet(phase, text: text, level: level)
                voice.engine = engine
                return VoicePillView(voice: voice)
            }
            let orbSize = CGSize(width: VoicePill.size.width, height: VoicePill.size.height)
            shot("voicepill-listening", hostedSize: orbSize, orb(.listening, "add dinner with Anna to my calendar tomorrow at seven", level: 0.6))
            shot("voicepill-needsmodel", hostedSize: orbSize, orb(.needsModel("English"), ""))
            shot("voicepill-denied", hostedSize: orbSize, orb(.micDenied, ""))
            shot("voiceorb-listening-silent", hostedSize: orbSize, orb(.listening, "", level: 0))
            shot("voiceorb-listening-loud", hostedSize: orbSize, orb(.listening, "what is the marginal cost of production", level: 0.8))
            shot("voiceorb-transcribing", hostedSize: orbSize, orb(.working("Transcribing…"), "what is the marginal cost of production"))
            shot("voiceorb-done", hostedSize: orbSize, orb(.idle, "What is the marginal cost of production?", engine: .groq))
            shot("voiceorb-message", hostedSize: orbSize, orb(.message("Didn't catch that. Hold Tab + Q and speak."), ""))
            shot("voiceorb-micdenied", hostedSize: orbSize, orb(.micDenied, ""))
            shot("voiceorb-badkey", hostedSize: orbSize, orb(.message(VoiceController.badKeyMessage), ""))
            shot("voiceorb-needsmodel", hostedSize: orbSize, orb(.needsModel("English"), ""))

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
            selected.mode = .all
            selected.selection = ref(0)
            shot("library-selected", margin: 16, hostedSize: size, window(selected))

            // A drag on its way to "Math": the lifted row, the hovered row, and the sector that is glowing.
            let drag = LibraryState()
            drag.mode = .all
            drag.selection = ref(0)
            drag.debugLift = ref(2)
            drag.dragging = ref(2).map { [$0] } ?? []
            drag.debugHover = ref(4)
            drag.debugDropTarget = "Math"
            shot("library-drag", margin: 16, hostedSize: size, window(drag))


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
                MerlinDoneBadge(on: false, size: 56)
                MerlinDoneBadge(on: true, size: 56)
                MerlinDoneBadge(on: true, size: 56, ink: Theme.accent.color, mark: Theme.onAccent.color)
                MerlinDoneBadge(on: true, size: 16)
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
            selecting.mode = .all
            selecting.selection = ref(0)
            selecting.selecting = true
            selecting.picked = Set([ref(1), ref(3)].compactMap { $0 })
            shot("library-select-tick", margin: 16, hostedSize: size, window(selecting))

            // The Assistant's card beside the sidebar.
            LibraryView.debugAssistantOpen = true
            shot("library-assistant", margin: 16, hostedSize: size, window(selected))
            // ...and in a short window, where the card must shrink and keep its top (and close button) inside.
            let short = LibraryPanel.floor // the window's smallest size
            shot("library-assistant-short", margin: 16, hostedSize: short,
                 LibraryView(state: selected, onAsk: { _, _ in }).frame(width: short.width, height: short.height))
            LibraryView.debugAssistantOpen = false

            let multi = LibraryState()
            multi.mode = .all
            multi.selection = ref(0)
            multi.multi = Set([ref(0), ref(1), ref(3)].compactMap { $0 })
            shot("library-multi", margin: 16, hostedSize: size, window(multi))

            let bin = LibraryState()
            bin.mode = .bin
            bin.selection = Library.shared.binned.first.map { ItemRef(kind: $0.kind, id: $0.id) }
            shot("library-bin", margin: 16, hostedSize: size, window(bin))

            // A row under the pointer (next to the picked one): background, active glyph, the ↵ hint.
            let hover = LibraryState()
            hover.mode = .all
            hover.selection = ref(0)
            hover.debugHover = ref(3)
            shot("library-hover", margin: 16, hostedSize: size, window(hover))

            // A sector open (its glyph in the list header), with the first row picked.
            let sectorOpen = LibraryState()
            sectorOpen.mode = .all
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
            none.mode = .all
            none.browsing = true
            none.query = "zzqx"
            shot("library-search-empty", margin: 16, hostedSize: size, window(none))

            // Sheets (R2): a named note with the economics table (rows added later, and a dated part under a divider), drawn
            // and in Edit mode; then the "Save to note" menu under an answer, and its "New note…" name box. The sheet is
            // removed for good afterwards, so the other pictures (and the dark pass) stay as they were.
            let sheetDate = ISO8601DateFormatter().date(from: "2026-11-23T12:00:00Z")!
            if let econ = Library.shared.createSheet(named: "Microeconomics terms", markup: MarkdownTable.economicsSample) {
                Library.shared.appendToSheet(econ.id, "| Term | Definition | Formula |\n|---|---|---|\n| Average cost | Total cost ==per unit== made. | $AC = \\frac{TC}{Q}$ |\n\nCheck these before the mock on 3 Dec.", date: sheetDate)
                let sheetState = LibraryState()
                sheetState.mode = .notebook
                sheetState.browsing = true
                sheetState.selection = ItemRef(kind: .note, id: econ.id)
                shot("sheet-1-library", margin: 16, hostedSize: size, window(sheetState))
                SheetDetail.debugStartEditing = true
                let editState = LibraryState()
                editState.mode = .notebook
                editState.browsing = true
                editState.selection = ItemRef(kind: .note, id: econ.id)
                shot("sheet-2-edit", margin: 16, hostedSize: size, window(editState))
                SheetDetail.debugStartEditing = false
                let menuSheets = [(id: econ.id, name: "Microeconomics terms"), (id: UUID(), name: "Physics formulas"), (id: UUID(), name: "Russian words")]
                shot("sheet-3-save-menu", hostedSize: CGSize(width: 296, height: 190),
                     panel(mode, radius: Theme.Radius.container, SaveToNoteMenu(sheets: menuSheets, onPick: { _ in }, onNew: { _ in })))
                shot("sheet-4-new-name", hostedSize: CGSize(width: 296, height: 190),
                     panel(mode, radius: Theme.Radius.container, SaveToNoteMenu(sheets: menuSheets, onPick: { _ in }, onNew: { _ in }, naming: true)))
                Library.shared.deleteSheet(econ.id)
                Library.shared.deleteForever(econ.id)
            }

            // The settings page inside the Library window (in the Library's place), with its "‹ Library" button and the window's
            // three buttons drawn where macOS puts them; at the usual size and at the window's smallest. Throwaway stores only.
            let settingsSectors = SectorStore(directory: tmp.appendingPathComponent("settings-sectors"), library: Library.shared)
            let answersSuite = "com.kien.merlin.uishots.answers"
            if let answers = UserDefaults(suiteName: answersSuite) {
                for (name, section, sz) in [("library-settings", LibrarySettingsView.Section.general, size),
                                            ("library-settings-min", LibrarySettingsView.Section.general, CGSize(width: 920, height: 520))] {
                    shot(name, margin: 16, hostedSize: sz,
                         LibrarySettingsView.inWindowShot(section: section, size: sz, dark: mode.dark, data: LibrarySettingsView.sampleData(),
                                                          sectorStore: settingsSectors, answersStore: answers))
                }
                UserDefaults.standard.removePersistentDomain(forName: answersSuite)
            }

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

    /// A wallpaper-like desktop behind the edge pictures: a dark blue-grey diagonal with a soft lighter band (dark mode),
    /// a bright light gradient (light mode).
    private static func edgeWall<V: View>(_ mode: Mode, _ view: V, pad: CGFloat = 56) -> some View {
        view
            .padding(pad)
            .background(
                ZStack {
                    LinearGradient(colors: mode.dark
                                   ? [Color(red: 0.10, green: 0.12, blue: 0.17), Color(red: 0.20, green: 0.24, blue: 0.31), Color(red: 0.08, green: 0.09, blue: 0.13)]
                                   : [Color(red: 0.93, green: 0.95, blue: 0.98), Color(red: 0.99, green: 0.97, blue: 0.93), Color(red: 0.86, green: 0.91, blue: 0.97)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    LinearGradient(stops: [
                        .init(color: .white.opacity(0), location: 0.35),
                        .init(color: .white.opacity(mode.dark ? 0.10 : 0.35), location: 0.5),
                        .init(color: .white.opacity(0), location: 0.65),
                    ], startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            )
    }

    /// The right part of a screen at rest: only the edge dot shows, at the middle of the right edge (a slim bezel beyond it).
    private static func edgeRest(_ state: EdgeDotState, _ caption: String, _ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                ZStack(alignment: .trailing) {
                    // The desktop: a plain wallpaper tone, a little different from the picture's backdrop.
                    Rectangle().fill(mode.dark ? Color(white: 0.16) : Color(white: 0.93))
                    EdgeDotView(state: state).padding(.trailing, EdgeDotWindow.inset)
                }
                Rectangle().fill(Color.black).frame(width: 6) // the bezel
            }
            .frame(width: 150, height: 180)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(caption).font(.mMeta).foregroundStyle(Theme.inkSecondary.color)
        }
    }

    /// The edge panel's model with made-up chats and notes, two fixture apps (Claude and Figma) and, with `music`, a song
    /// playing with a generated cover. Fakes only: nothing launched, no live Spotify, throwaway defaults.
    private static func edgeModel(_ section: EdgePanelModel.Section?, hovering: Bool = false, empty: Bool = false,
                                  music: Bool = false, spotify state: SpotifyState? = nil, apps count: Int = 2,
                                  songs: SpotifySongs? = nil, cover: NSImage? = nil) -> EdgePanelModel {
        let (defaults, name) = EdgeDockFixtures.defaults()
        // The first `count` of the shot apps pinned (a fixed list, so the picture is the same on every Mac).
        if let data = try? JSONEncoder().encode(Array(ShotDockWorkspace.apps.prefix(count))) {
            defaults.set(data, forKey: DockAppStore.defaultsKey)
        }
        let apps = DockAppStore(defaults: defaults, workspace: ShotDockWorkspace())
        EdgeDockFixtures.forget(name)
        let backend = FixtureSpotifyBackend(state ?? (music ? .track(EdgeDockFixtures.track) : .notRunning))
        let spotify = EdgeDockFixtures.spotify(backend, cover: music ? (cover ?? EdgeDockFixtures.coverImage()) : nil)
        if section == .apps {
            apps.loadInstalled()
            EdgeDockFixtures.waitUntil { !apps.installed.isEmpty }
        }
        let m = EdgePanelModel(apps: apps, spotify: spotify, songs: songs ?? SpotifySongs(folder: nil))
        let owners = (0..<3).map { _ in NSObject() }
        edgeOwners.append(contentsOf: owners)
        m.chats = [
            .init(id: ObjectIdentifier(owners[0]), title: "Closures capture by reference", subtitle: "Searching the web…", phase: .working, isOpen: true, canStar: true),
            .init(id: ObjectIdentifier(owners[1]), title: "Supply shift effects", subtitle: "Done · click to read", phase: .done, isOpen: false, starred: true, canStar: true),
            .init(id: ObjectIdentifier(owners[2]), title: "Stress in замок", subtitle: "Something went wrong", phase: .failed, isOpen: false, canStar: true),
        ]
        m.notes = empty ? [] : [
            .init(id: UUID(), title: "Microeconomics terms", detail: "Changed 5 min ago"),
            .init(id: UUID(), title: "Physics: forces", detail: "Changed yesterday"),
            .init(id: UUID(), title: "Macro essay plan", detail: "Changed 3 days ago"),
        ]
        m.section = section
        m.shown = true
        m.hoveringBox = hovering
        return m
    }
    /// Keeps the rows' made-up owners alive while the pictures are drawn (their ids must stay unique).
    private static var edgeOwners: [NSObject] = []

    /// The full dock with the search field open and `query` typed (set on the model, as the tests do).
    private static func edgeSearchModel(_ query: String) -> EdgePanelModel {
        let m = edgeModel(nil, music: true, apps: 6)
        m.openSearch()
        m.query = query
        return m
    }

    /// The Spotify card with sample saved songs (memory only) and a query or the star filter set on the model.
    private static func edgeSongsModel(query: String = "", starred: Bool = false, empty: Bool = false) -> EdgePanelModel {
        // Empty: nothing playing either (a playing song would be saved at once).
        let m = edgeModel(.spotify, music: !empty, spotify: empty ? .stopped : nil,
                          songs: empty ? SpotifySongs(folder: nil) : EdgeDockFixtures.songs())
        m.songsQuery = query
        m.songsStarredOnly = starred
        return m
    }

    /// The Spotify card after a Web API search (a fake search: no key, no network): no saved match, five Spotify songs.
    private static func edgeSpotifyHitsModel() -> EdgePanelModel {
        let m = edgeSongsModel(query: "harbour lights")
        m.webSearch = PictureWebSearch()
        m.searchSpotify()
        let end = Date().addingTimeInterval(1)
        while m.webHits.isEmpty && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return m
    }

    private static func edgeAppsModel(query: String = "", apps count: Int = 2,
                                      filter: EdgePanelModel.AppsFilter = .all) -> EdgePanelModel {
        let m = edgeModel(.apps, apps: count)
        m.appsQuery = query
        m.appsFilter = filter
        return m
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

    /// A finished chat whose answer is the price ceiling board.
    private static func boardChatModel() -> AskModel {
        let selection = Selection(text: "A binding price ceiling leads to a shortage.",
                                  appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: selection, footnote: "Sonnet · sees your screen")
        model.turns = [AskModel.Turn(question: "Why does a price ceiling cause a shortage?",
                                     answer: "A ceiling below P* changes both sides of the market at once.\n<board>\(BoardSpec.priceCeilingSample)</board>",
                                     done: true)]
        return model
    }

    /// A finished chat whose answer is the economics terms table; `large` is the wide (1.5×) chat. Settings are not touched.
    private static func tableChatModel(large: Bool) -> AskModel {
        let selection = Selection(text: "Price elasticity of demand measures how responsive quantity demanded is to price.",
                                  appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: selection, footnote: "Sonnet · sees your screen")
        model.isLarge = large
        model.turns = [AskModel.Turn(question: "Make a table of 5 microeconomics terms with definitions and formulas.",
                                     answer: MarkdownTable.economicsSample, done: true)]
        return model
    }

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

/// The edge pictures' apps: real system apps, so the ring shows real macOS icons. Read-only: the icon is looked up by
/// bundle ID (`urlForApplication` + `icon(forFile:)`), nothing is opened or launched. An app this Mac lacks gets the
/// fixture's generated icon.
private struct ShotDockWorkspace: DockWorkspace {
    static let apps: [DockApp] = [
        DockApp(bundleID: "com.apple.iCal", name: "Calendar"),
        DockApp(bundleID: "com.apple.mail", name: "Mail"),
        DockApp(bundleID: "com.apple.Notes", name: "Notes"),
        DockApp(bundleID: "com.apple.Music", name: "Music"),
        DockApp(bundleID: "com.apple.Safari", name: "Safari"),
        DockApp(bundleID: "com.apple.Preview", name: "Preview"),
        DockApp(bundleID: "com.apple.Maps", name: "Maps"),
        DockApp(bundleID: "com.apple.Photos", name: "Photos"),
    ]

    func url(forBundleID id: String) -> URL? { URL(fileURLWithPath: "/fixture/\(id).app") }
    func open(_ url: URL) {}
    func installedApps() -> [DockApp] { Self.apps }
    func icon(for url: URL) -> NSImage {
        let id = url.deletingPathExtension().lastPathComponent
        guard let real = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else {
            return FixtureDockWorkspace().icon(for: url)
        }
        return NSWorkspace.shared.icon(forFile: real.path)
    }
}

/// Five made-up Spotify songs for the pictures (no network).
private final class PictureWebSearch: SpotifyWebSearching {
    var hasKey: Bool { true }
    func search(_ query: String) async -> Result<[SpotifyHit], SpotifyWebSearch.Failure> {
        let rows = [("Harbour Lights", "Mira Vale"), ("Lights Over the Harbour", "Lo Fen"), ("Harbour", "North Coast"),
                    ("Harbour Lights (Live)", "Mira Vale"), ("Night Harbour", "Ka, Oren Pell")]
        return .success(rows.enumerated().map { i, r in
            SpotifyHit(uri: "spotify:track:" + String(format: "%022d", 900 + i), name: r.0, artist: r.1)
        })
    }
}
