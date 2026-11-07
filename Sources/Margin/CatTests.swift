import AppKit
import Foundation
import SwiftUI

extension FeatureTests {
    /// The pixel cats: the atlas decodes, every coat has every pose, the feet stay on one line, and the agent's state picks the pose.
    static func catChecks(_ check: (String, Bool) -> Void) {
        let columns = CatAtlas.columns, rows = CatAtlas.rows, cw = CatAtlas.cellWidth, ch = CatAtlas.cellHeight
        check("cats: the atlas decodes at its stated size", PixelCat.atlasImage?.width == columns * cw && PixelCat.atlasImage?.height == rows * ch)
        check("cats: one coat per row", PixelCat.coats.count == rows && Set(PixelCat.coats.map(\.name)).count == rows)

        /// The first and last picture row with a visible pixel, and how many pixels are solid.
        func extent(_ image: CGImage) -> (top: Int, bottom: Int, solid: Int)? {
            let w = image.width, h = image.height
            var data = [UInt8](repeating: 0, count: w * h * 4)
            guard let context = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            var top = Int.max, bottom = -1, solid = 0
            for y in 0..<h { for x in 0..<w where data[(y * w + x) * 4 + 3] > 128 {
                top = min(top, y); bottom = max(bottom, y); solid += 1
            } }
            return bottom < 0 ? nil : (top, bottom, solid)
        }
        func bytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }

        let poses: [PixelCat.Pose] = [.sit, .run(0), .run(1), .run(2), .run(3), .loaf, .sleep]
        var missing = 0, empty = 0, wrongSize = 0
        var bottoms: [Int] = [], sleeperTops: [Int] = []
        for coat in 0..<PixelCat.coats.count {
            for pose in poses {
                guard let image = PixelCat.image(coat: coat, pose: pose) else { missing += 1; continue }
                if image.width != cw || image.height != ch { wrongSize += 1 }
                guard let e = extent(image), e.solid > 400 else { empty += 1; continue }
                bottoms.append(e.bottom)
                if pose == .sleep { sleeperTops.append(e.top) }
            }
        }
        check("cats: all 8 coats have all 6 poses", missing == 0 && empty == 0)
        check("cats: every picture is one cell", wrongSize == 0)
        let low = bottoms.min() ?? 0, high = bottoms.max() ?? 0
        check("cats: the feet of every coat and pose are on one line (\(low)–\(high))", !bottoms.isEmpty && high - low <= 2)
        let flat = (sleeperTops.min() ?? 0, sleeperTops.max() ?? 99)
        check("cats: every sleeper has its zzz at about the same height (\(flat.0)–\(flat.1))", sleeperTops.count == PixelCat.coats.count && flat.1 - flat.0 <= 5)

        // Poses differ, and the trot reuses its walking picture.
        let pictures = poses.compactMap { PixelCat.image(coat: 0, pose: $0).flatMap(bytes) }
        check("cats: standing, loaf and asleep are three different pictures", pictures.count == poses.count
              && Set([pictures[0], pictures[5], pictures[6]]).count == 3)
        check("cats: the trot has three different pictures in four steps", Set([pictures[1], pictures[2], pictures[3], pictures[4]]).count == 3
              && pictures[2] == pictures[4])
        let sameRow = (0..<PixelCat.coats.count).map { PixelCat.image(coat: $0, pose: .sit).flatMap(bytes) }
        check("cats: each coat looks different", Set(sameRow).count == PixelCat.coats.count)
        check("cats: a coat number past the end wraps around", PixelCat.image(coat: PixelCat.coats.count + 2, pose: .loaf).flatMap(bytes)
              == PixelCat.image(coat: 2, pose: .loaf).flatMap(bytes))

        // Breathing: one picture pixel taller, paws fixed, hard pixels; and slow.
        var breathOK = 0
        for coat in 0..<PixelCat.coats.count {
            guard let out = PixelCat.bigSleeping(coat: coat), let inn = PixelCat.bigSleepingInhaled(coat: coat),
                  let a = extent(out), let b = extent(inn), inn.width == out.width, inn.height == out.height else { continue }
            if b.bottom == a.bottom && b.top == a.top - CatSleepAtlas.block && bytes(inn) != bytes(out) { breathOK += 1 }
        }
        check("cats: breathing in lifts every sleeper one block of the art and leaves its paws put (\(breathOK) of \(PixelCat.coats.count))", breathOK == PixelCat.coats.count)
        let samples = stride(from: 0.0, to: 40.0, by: 0.05).map { SleepingCatView.inhaled(at: $0) }
        let share = Double(samples.filter { $0 }.count) / Double(samples.count)
        check("cats: a breath is in for about 45% of the time (\(Int(share * 100))%)", share > 0.40 && share < 0.50)
        // The z's: separate pictures above the cat, appearing one after another, floating up, then fading together.
        var zOK = 0
        for coat in 0..<PixelCat.coats.count {
            guard let cat = PixelCat.bigSleeping(coat: coat).flatMap(extent) else { continue }
            let zs = (0..<CatSleepAtlas.zCount).compactMap { PixelCat.bigZ(coat: coat, $0).flatMap(extent) }
            if zs.count == CatSleepAtlas.zCount, zs.allSatisfy({ $0.bottom < cat.top + 40 && $0.top < cat.top }) { zOK += 1 }
        }
        check("cats: every sleeper has \(CatSleepAtlas.zCount) separate z's above it (\(zOK) of \(PixelCat.coats.count))", CatSleepAtlas.zCount == 3 && zOK == PixelCat.coats.count)
        check("cats: the z's start one after another", SleepingCatView.zState(at: 0.1, index: 0).opacity == 0
              && SleepingCatView.zState(at: 1.0, index: 0).opacity > 0 && SleepingCatView.zState(at: 1.0, index: 2).opacity == 0
              && SleepingCatView.zState(at: 2.6, index: 2).opacity > 0)
        check("cats: ...float up in whole steps and stop after 3", SleepingCatView.zState(at: 1.0, index: 0).rise < SleepingCatView.zState(at: 3.0, index: 0).rise
              && (0..<100).allSatisfy { SleepingCatView.zState(at: Double($0) * 0.05, index: 0).rise <= 3 })
        check("cats: ...and all fade away before the next round", SleepingCatView.zState(at: 4.95, index: 0).opacity < 0.1
              && SleepingCatView.zState(at: 4.95, index: 2).opacity < 0.1 && SleepingCatView.zState(at: 5.05, index: 2).opacity == 0)
        check("cats: neighbours aren't breathing in step", (0..<80).contains { SleepingCatView.inhaled(at: Double($0) * 0.1) != SleepingCatView.inhaled(at: Double($0) * 0.1, offset: 0.37) })
        let screen = NSRect(x: 0, y: 40, width: 1440, height: 800)
        let one = AgentBar.restFrame(count: 1, in: screen), three = AgentBar.restFrame(count: 3, in: screen), nine = AgentBar.restFrame(count: 9, in: screen)
        check("cats: the resting cat sits in the bottom-right corner, paws on the edge", one.maxX == screen.maxX - AgentBar.Layout.restInset
              && one.minY == screen.minY - AgentBar.Layout.restSink)
        check("cats: more agents grow it to the left, along the bottom", three.maxX == one.maxX && three.minY == one.minY && three.width > one.width
              && three.width == one.width + 2 * AgentBar.Layout.restSpacing)
        check("cats: ⌘⇧C is the call-back chord, and only with Command and Shift", Hotkeys.action(keyCode: 8, flags: [.maskCommand, .maskShift], tabHeld: false) == .cat
              && Hotkeys.action(keyCode: 8, flags: [.maskCommand], tabHeld: false) == nil
              && Hotkeys.action(keyCode: 8, flags: [.maskCommand, .maskShift, .maskAlternate], tabHeld: false) == nil)
        func plan(_ prompt: String, selection: String = "a parabola", snip: Bool = false, blank: Bool = false, sees: Bool = true) -> Router.Plan {
            Router.plan(.init(prompt: prompt, selection: selection, hasSnip: snip, isBlank: blank, localMode: true, localSeesImages: sees))
        }
        check("haiku: a snip goes to the quick model, which can see it", plan("What is this?", selection: "", snip: true).isLocal && plan("What is this?", selection: "", snip: true).sees)
        check("haiku: a blank chat goes to the quick model, with the screenshot", plan("What's on my screen?", selection: "", blank: true).isLocal)
        check("haiku: a question about the screen stays with the quick model", plan("What does this button do on my screen?").isLocal)
        check("haiku: the web, quizzes and pronunciation still go to Claude",
              !plan("What's the latest version?", snip: true).isLocal && !plan(Prompts.quiz).isLocal && !plan(Prompts.pronounce, snip: true).isLocal)
        check("haiku: a model that can't see (Ollama) still sends snips and the screen to Claude",
              !plan("What is this?", selection: "", snip: true, sees: false).isLocal && !plan("What does this button do on my screen?", sees: false).isLocal)
        check("haiku: a chat that sees isn't moved to Claude for a screen question",
              !Router.needsEscalation("What about this button on my screen?", from: plan("Explain this")) && Router.needsEscalation("latest price?", from: plan("Explain this")))
        check("cats: a 6 second hover wakes them", AgentBar.Layout.wakeAfter == 6)
        check("cats: awake pictures are about as big as the sleepers", abs(AwakeCatView.size().width - PixelCat.bigCell.width * CGFloat(AgentBar.Layout.restPixels) / 10) < 60)
        check("cats: past \(AgentBar.Layout.restMaxCats) agents it stops growing (a +n is shown)", nine.width == AgentBar.restFrame(count: AgentBar.Layout.restMaxCats + 1, in: screen).width
              && nine.width > AgentBar.restFrame(count: AgentBar.Layout.restMaxCats, in: screen).width)

        // The Qwen/Claude button's words.
        check("button: Claude says Claude", EngineLabel.name(local: false, model: "qwen3:8b") == "Claude")
        check("button: qwen3:8b says Qwen", EngineLabel.name(local: true, model: "qwen3:8b") == "Qwen")
        check("button: llama3.2:3b says Llama, an odd name still says something", EngineLabel.name(local: true, model: "llama3.2:3b") == "Llama"
              && EngineLabel.name(local: true, model: "3b") == "Local")

        // The agent's state picks the pose.
        let task = BackgroundTask(kind: .find, title: "Find: elasticity")
        check("cats: a working agent runs", AgentSlotView.mood(task) == .running)
        task.queued = true
        check("cats: ...asleep while it waits its turn", AgentSlotView.mood(task) == .asleep)
        check("cats: ...and asleep stays asleep when the bar is hidden", AgentSlotView.restingMood(task) == .asleep)
        task.queued = false
        check("cats: ...mid-stride when the bar is hidden", AgentSlotView.restingMood(task) == .paused)
        task.state = .needsApproval
        check("cats: waiting for your OK it stands", AgentSlotView.mood(task) == .idle)
        task.state = .done
        check("cats: finished it loafs", AgentSlotView.mood(task) == .done)
        task.state = .failed("no")
        check("cats: failed it stands", AgentSlotView.mood(task) == .idle)
        task.state = .cancelled
        check("cats: denied it stands", AgentSlotView.mood(task) == .idle)
    }
}

extension FeatureTests {
    /// Margin --barpicture <png>: the agent bar, the minimized strip, the empty bar and the voice pill's cat drawn to one picture. No window,
    /// no Claude, nothing touched: this is how to look at the bar without it popping up on your screen.
    @MainActor
    static func barPicture(path: String) -> Never {
        if renderBarPictures(path: path, scheme: .dark) { print("BARPICTURE saved \(path)"); exit(0) }
        print("BARPICTURE failed"); exit(1)
    }

    /// The pictures behind `--barpicture` (and `--uishots`): writes `path`, `path.chat.png` and `path.breath.png`.
    @MainActor
    static func renderBarPictures(path: String, scheme: ColorScheme) -> Bool {
        _ = NSApplication.shared
        let model = AgentBarModel()
        func task(_ kind: BackgroundTask.Kind, _ title: String, _ detail: String, _ state: BackgroundTask.State, queued: Bool = false, plan: Bool = false) -> BackgroundTask {
            let t = BackgroundTask(kind: kind, title: title)
            t.detail = detail
            t.state = state
            t.queued = queued
            if plan { t.plan = TaskPlan(headline: "x", groups: [PlanGroup(title: "Sort 112 screenshots", symbol: "photo", ops: [])]) }
            return t
        }
        let running = task(.study, "Study: Econ ch. 4", "Writing summaries: 2 of 5", .working)
        running.fraction = 0.4
        let asking = task(.tidy, "Tidy Desktop", "Waiting for your OK", .needsApproval, plan: true)
        let done = task(.find, "Find: elasticity PDF", "Found 3 files", .done)
        done.report = TaskReport(headline: "Found 3 files")
        let waiting = task(.batch, "Merge PDFs", "Waiting for another task to finish…", .working, queued: true)
        model.tasks = [running, asking, done, waiting]
        for (i, t) in model.tasks.enumerated() { model.coats[t.id] = [0, 4, 6, 3][i] }
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 600)
        let restFour = AgentBar.restFrame(count: 4, in: screen), restOne = AgentBar.restFrame(count: 1, in: screen)
        let barWidth = 2 * AgentBar.Layout.pad + 4 * AgentBar.Layout.slotWidth + 3 * AgentBar.Layout.gap + AgentBar.Layout.newJobWidth
            + AgentBar.Layout.minimizeWidth + AgentBar.Layout.gap
        let picture = VStack(alignment: .leading, spacing: 16) {
            AgentBarView(model: model).frame(width: barWidth, height: AgentBar.Layout.height)
            HStack(alignment: .top, spacing: 24) {
                AgentStripView(model: model).frame(width: restFour.width, height: restFour.height)
                AgentStripView(model: AgentBarModel()).frame(width: restOne.width, height: restOne.height)
                AgentBarView(model: AgentBarModel()).frame(width: AgentBar.Layout.emptyWidth + 60, height: AgentBar.Layout.height)
                HStack(spacing: 6) {
                    PixelCatView(coat: 3, mood: .idle, roam: 0, pixels: 3).frame(width: 36, height: 36)
                    Text("Listening…").foregroundStyle(.white)
                }
                .padding(10).background(RoundedRectangle(cornerRadius: 16).fill(Color(white: 0.06)))
            }
            // Woken by a long hover: sitting up, running out (facing right), running back in (facing left).
            HStack(alignment: .top, spacing: 24) {
                ForEach([AgentBarModel.RestPhase.waking, .leaving, .returning], id: \.self) { phase in
                    let m = AgentBarModel()
                    let _ = { m.tasks = model.tasks; m.coats = model.coats; m.restPhase = phase }()
                    AgentStripView(model: m).frame(width: restFour.width, height: restFour.height)
                }
            }
        }
        .padding(20).background(Color(white: 0.3))
        // The chat box with the engine button, answered by Claude and by the model on this Mac.
        func chat(_ engine: AskModel.Engine) -> some View {
            let m = AskModel(selection: Selection(text: "A parabola opens up when a is positive.", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero),
                             footnote: engine.isLocal ? "qwen3:8b · on your Mac · nothing sent to Claude · ⌃⇧L for Claude" : "Sonnet · web search on")
            m.engine = engine
            return AskView(model: m).frame(width: 360, height: 130).background(Color(nsColor: .windowBackgroundColor))
        }
        // The breath: a cat out, then in, then out again, at 4×, with hard pixels.
        func closeUp(_ image: CGImage?) -> some View {
            Group { if let image { Image(decorative: image, scale: 1).interpolation(.none).resizable().frame(width: 226, height: 207) } }
        }
        let breath = HStack(spacing: 8) {
            closeUp(PixelCat.bigSleeping(coat: 0)); closeUp(PixelCat.bigSleepingInhaled(coat: 0))
            closeUp(PixelCat.bigSleeping(coat: 3)); closeUp(PixelCat.bigSleepingInhaled(coat: 3))
        }.padding(10).background(Color(white: 0.3))
        let breathRenderer = ImageRenderer(content: breath)
        if let b = breathRenderer.cgImage {
            try? NSBitmapImageRep(cgImage: b).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".breath.png"))
        }
        let boxes = HStack(spacing: 16) { chat(.init(name: "Claude", isLocal: false)); chat(.init(name: "Qwen", isLocal: true)) }.padding(20).background(Color(white: 0.3))
        let boxRenderer = ImageRenderer(content: boxes.environment(\.colorScheme, scheme))
        boxRenderer.scale = 2
        if let box = boxRenderer.cgImage {
            try? NSBitmapImageRep(cgImage: box).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path + ".chat.png"))
        }
        let renderer = ImageRenderer(content: picture.environment(\.colorScheme, scheme))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              (try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))) != nil else {
            return false
        }
        return true
    }
}
