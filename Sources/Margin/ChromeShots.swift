import AppKit
import SwiftUI

/// `Margin --chromeshots <dir>`: headless pictures of the popup chrome at its natural height (chat states, quiz, event card, task box),
/// light and dark. Nothing is ever shown on screen.
enum ChromeShots {
    @MainActor static func run(directory: String) -> Never {
        _ = NSApplication.shared
        Motion.still = true
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [("dark", ColorScheme.dark, NSAppearance(named: .darkAqua)!), ("light", .light, NSAppearance(named: .aqua)!)] {
            NSApp.appearance = appearance
            func save<V: View>(_ file: String, width: CGFloat, _ view: V) {
                let framed = view.frame(width: width).padding(24)
                    .background(LinearGradient(colors: scheme == .dark ? [Color(white: 0.22), Color(white: 0.30)] : [Color(white: 0.74), Color(white: 0.84)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .environment(\.colorScheme, scheme)
                let host = NSHostingView(rootView: framed)
                host.appearance = appearance
                host.frame = NSRect(x: 0, y: 0, width: width + 48, height: 900)
                for _ in 0..<4 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.12)) }
                let fit = host.fittingSize
                host.frame = NSRect(origin: .zero, size: CGSize(width: width + 48, height: max(60, fit.height)))
                for _ in 0..<2 { host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(file)-\(name).png"))
            }
            func panel<V: View>(_ v: V) -> some View {
                v.background(Color(white: scheme == .dark ? 0.20 : 0.96))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            func model(_ turns: [AskModel.Turn], streaming: Bool = false) -> AskModel {
                let sel = Selection(text: "A closure captures the variables around it by reference, so a later change is visible inside it.",
                                    appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
                let m = AskModel(selection: sel, footnote: "Sonnet · web search on · sees your screen")
                m.turns = turns; m.isStreaming = streaming
                if streaming { m.status = "Searching “swift closures capture list”" }
                return m
            }
            let quiz = """
            {"title":"Closures","questions":[{"q":"What does a closure capture by default?","options":["A copy","A reference","Nothing","A weak ref"],"correct":1,"why":"Captured variables are shared."},{"q":"Name the capture list syntax","answer":"[x]","why":"Square brackets"}]}
            """
            save("c-empty", width: 420, panel(AskView(model: model([]))))
            save("c-thinking", width: 420, panel(AskView(model: model([AskModel.Turn(question: "Can you give me an example?")], streaming: true))))
            save("c-answer", width: 420, panel(AskView(model: model([AskModel.Turn(question: "Can you give me an example?", answer: "A closure **keeps the variable alive** and sees later changes.\n\n- Captured variables are shared\n- Use `[weak self]`\n\nSources: [Swift book](https://docs.swift.org/x), [Apple](https://developer.apple.com/y)", done: true)]))))
            let picker = model([]); picker.learnMode = true
            save("c-hint-picker", width: 420, panel(AskView(model: picker)))
            let typed = model([]); typed.learnMode = true; typed.hintQuestion = "Why does it see later changes?"
            save("c-hint-typed", width: 420, panel(AskView(model: typed)))
            let hinted = model([AskModel.Turn(question: Prompts.hintLabel(1), answer: "Think about what the closure holds on to: the value, or the variable itself?", done: true)])
            hinted.learnMode = true; hinted.hintLevel = 1
            save("c-hint-answer", width: 420, panel(AskView(model: hinted)))
            let blank = Selection(text: "", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
            save("c-learn-blank-off", width: 420, panel(AskView(model: AskModel(selection: blank, footnote: "Sonnet · web search on"))))
            let blankOn = AskModel(selection: blank, footnote: "Sonnet · web search on"); blankOn.learnMode = true
            save("c-learn-blank-on", width: 420, panel(AskView(model: blankOn)))
            let blankTyped = AskModel(selection: blank, footnote: "Sonnet · web search on"); blankTyped.learnMode = true; blankTyped.hintQuestion = "What is a derivative?"
            save("c-learn-blank-typed", width: 420, panel(AskView(model: blankTyped)))
            let full = model([AskModel.Turn(question: Prompts.hintLabel(4), answer: "The closure holds a **reference to the variable**, so a later change is visible inside it.", done: true)])
            full.learnMode = true; full.hintLevel = 4
            save("c-hint-full", width: 420, panel(AskView(model: full)))
            save("c-quiz", width: 400, panel(QuizView(source: quiz, index: 0, picked: 0).padding(14)))
            save("c-event", width: 400, panel(EventCard(source: EventCard.encode(CalendarIntent.Draft(title: "Dinner with Sam", start: Date(), end: Date().addingTimeInterval(5400)))).padding(14)))
            save("c-taskbox", width: 580, TaskBoxView(state: TaskBoxState()))
            let t = BackgroundTask(kind: .tidy, title: "Tidy Desktop")
            t.state = .needsApproval
            t.plan = TaskPlan(headline: "Move 14 files into 3 folders", groups: [])
            save("c-taskcard", width: 430, TaskCardView(task: t, onClose: {}, onResize: { _ in }))
        }
        exit(0)
    }
}
