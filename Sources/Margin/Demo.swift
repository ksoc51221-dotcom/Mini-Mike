import AppKit
import SwiftUI

/// `Margin --demo <dir>`: drives one real agent through open → ask → stream → minimize →
/// done → expand → close, saving snapshots of Margin's own windows (no screen permission needed).
/// Never takes keyboard focus.
enum Demo {
    /// `Margin --videodemo <dir>`: a real YouTube summary, plus the listen-along and
    /// "which style?" screens, saved as snapshots (never takes focus).
    static func videos(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 700, y: screen.visibleFrame.maxY - 120)

        // 1. Listen along, mid-listen (no audio is captured in the demo).
        dock.openVideo(.listen, near: point)
        let listen = dock.debugAgents[0]
        after(0.8) {
            listen.debugSetVideoStage(.listening(elapsed: 192, caption:
                "so the instant gratification monkey takes the wheel, and the rational decision-maker just watches"))
            after(0.6) {
                save("video-1-listening.png", listen.debugSnapshot())
                // 2. A Russian video: Margin asks how to summarize it.
                listen.debugTranscriptReady(VideoTranscript(title: "Как выучить язык за год", channel: nil,
                                                            duration: 600, languageCode: "ru", origin: "demo",
                                                            segments: [.init(start: 0, text: "Привет всем")]))
                after(0.6) {
                    save("video-2-choose-style.png", listen.debugSnapshot())
                    listen.close()
                    // 3. A real YouTube video, start to finish.
                    after(0.5) {
                        dock.openVideo(.youtube(id: "arj7oStGLkU"), near: point)
                        guard let yt = dock.debugAgents.last else { exit(1) }
                        after(1.0) { save("video-3-fetching.png", yt.debugSnapshot()) }
                        func waitDone(_ tries: Int) {
                            if yt.phase == .done || yt.phase == .failed || tries == 0 {
                                after(1.5) {
                                    save("video-4-summary.png", yt.debugSnapshot())
                                    yt.close()
                                    after(0.4) { print("VIDEODEMO DONE (\(yt.phase))"); exit(0) }
                                }
                            } else { after(0.5) { waitDone(tries - 1) } }
                        }
                        waitDone(240)
                    }
                }
            }
        }
        app.run()
        exit(0)
    }

    /// `Margin --voicedemo <dir>`: a chat with a pronunciation answer (no Claude call, no sound),
    /// saving snapshots of the voice message ready and mid-play.
    /// Sample graphs covering what Claude is taught to draw (also handy for checking the renderer by eye).
    static let graphSamples: [(name: String, json: String)] = [
        ("quadratic", #"""
        {"title":"y = a(x − h)² + k","x":{"min":-6,"max":6},"y":{"min":-5,"max":10},
         "sliders":[{"name":"a","min":-2,"max":2,"value":1,"step":0.1},{"name":"h","min":-4,"max":4,"value":1},{"name":"k","min":-4,"max":6,"value":-2}],
         "plots":[{"name":"f","y":"a(x-h)^2+k","label":"f(x)"}],
         "points":[{"label":"vertex","x":"h","y":"k","guides":true},{"label":"root","intersect":["f","0"],"all":true,"hollow":true}],
         "lines":[{"x":"h","label":"axis of symmetry"}],
         "caption":"Drag a, h and k: h and k move the vertex; a stretches the parabola and flips it when negative."}
        """#),
        ("supply-demand", #"""
        {"title":"Supply and demand","x":{"label":"Quantity","min":0,"max":10,"numbers":false},
         "y":{"label":"Price","min":0,"max":10,"numbers":false},
         "sliders":[{"name":"shift","label":"Demand shift","min":-2,"max":2,"value":0}],
         "plots":[{"name":"D","y":"8-0.7*x+shift","label":"D","color":"blue"},{"name":"S","y":"1+0.6*x","label":"S","color":"orange"}],
         "points":[{"name":"E","intersect":["D","S"],"label":"E","guides":["Q*","P*"]}],
         "areas":[{"between":["D","E.y"],"from":0,"to":"E.x","label":"CS"},{"between":["E.y","S"],"from":0,"to":"E.x","label":"PS"}],
         "caption":"Raise demand: the equilibrium moves up and to the right, so price and quantity both rise."}
        """#),
        ("tangent", #"""
        {"title":"The slope of a tangent","x":{"min":-3,"max":3},"y":{"min":-3,"max":3},
         "sliders":[{"name":"a","label":"x = a","min":-2.5,"max":2.5,"value":1.5}],
         "plots":[{"name":"f","y":"x^3/3 - x","label":"f"},{"name":"g","y":"x^2 - 1","label":"f′","dashed":true,"color":"gray"}],
         "points":[{"on":"f","x":"a","label":"(a, f(a))"}],
         "lines":[{"tangent":"f","at":"a","label":"tangent","color":"orange","dashed":false}],
         "caption":"The tangent is flat exactly where f′ crosses zero."}
        """#),
        ("sine", #"""
        {"title":"y = A·sin(Bx)","x":{"min":0,"max":"2*pi"},"y":{"min":-3,"max":3},
         "sliders":[{"name":"A","label":"amplitude A","min":0.5,"max":2.5,"value":2},{"name":"B","label":"frequency B","min":0.5,"max":3,"value":1}],
         "plots":[{"y":"A*sin(B*x)","label":"y"}]}
        """#),
        ("unit-circle", #"""
        {"title":"The unit circle","equal":true,"x":{"min":-1.5,"max":1.5},"y":{"min":-1.3,"max":1.3},
         "sliders":[{"name":"theta","label":"angle θ","min":0,"max":"2*pi","value":0.9}],
         "shapes":[{"circle":[0,0,1],"color":"gray"},
                   {"segment":[[0,0],["cos(theta)","sin(theta)"]],"color":"orange"},
                   {"segment":[["cos(theta)",0],["cos(theta)","sin(theta)"]],"dashed":true,"label":"sin θ","color":"blue"},
                   {"segment":[[0,0],["cos(theta)",0]],"label":"cos θ","color":"green"}],
         "points":[{"x":"cos(theta)","y":"sin(theta)","label":"(cos θ, sin θ)"}]}
        """#),
        ("circular-flow", #"""
        {"title":"The circular flow of income","axes":false,"x":{"min":0,"max":10},"y":{"min":0,"max":6},
         "shapes":[{"box":[1.8,3,2.8,1.3],"label":"Households"},{"box":[8.2,3,2.8,1.3],"label":"Firms"},
                   {"arrow":[[3.4,4.3],[6.6,4.3]],"label":"spending","color":"green"},
                   {"arrow":[[6.6,5.2],[3.4,5.2]],"label":"goods & services","color":"blue"},
                   {"arrow":[[6.6,1.7],[3.4,1.7]],"label":"wages","color":"green"},
                   {"arrow":[[3.4,0.8],[6.6,0.8]],"label":"labor","color":"blue"}]}
        """#),
        ("normal", #"""
        {"title":"How likely is Z < z?","x":{"min":-4,"max":4},"y":{"min":0,"max":0.45},
         "sliders":[{"name":"z","min":-3,"max":3,"value":1}],
         "plots":[{"name":"p","y":"exp(-x^2/2)/sqrt(2*pi)","label":"bell curve"}],
         "areas":[{"under":"p","from":-4,"to":"z","label":"P(Z < z)"}],
         "lines":[{"x":"z","label":"z"}]}
        """#),
    ]

    /// `Margin --graphdemo <dir>`: renders every sample graph (dark and light), plus a chat with a graph answer.
    @MainActor
    static func graphs(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        for (name, json) in graphSamples {
            guard let spec = GraphSpec.parse(json) else { print("  \(name): didn't parse"); continue }
            if !spec.problems.isEmpty { print("  \(name) problems: \(spec.problems)") }
            for dark in [true, false] {
                let width: CGFloat = 340
                let renderer = ImageRenderer(content:
                    GraphCanvas(spec: spec, values: spec.initialValues, hover: nil, dark: dark)
                        .frame(width: width, height: width * spec.aspect)
                        .padding(10)
                        .background(dark ? Color(white: 0.16) : Color(white: 0.97)))
                renderer.scale = 2
                save("graph-\(name)\(dark ? "" : "-light").png", renderer.cgImage)
            }
        }

        // A real chat with a graph answer, as it looks in the popup.
        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 560, y: screen.visibleFrame.maxY - 140)
        let selection = Selection(text: "the market reaches equilibrium where supply meets demand", appName: "Safari",
                                  context: ContextBox(resolved: nil), pid: 0, mouse: point)
        dock.open(selection, iconFrame: NSRect(x: point.x, y: point.y - 26, width: 26, height: 26))
        guard let agent = dock.debugAgents.first else { print("GRAPHDEMO FAIL"); exit(1) }
        after(0.6) {
            agent.debugInject(question: "Show me this visually", answer: """
            Equilibrium is where the two curves cross: at that price, buyers want exactly what sellers offer.

            <graph>\(graphSamples[1].json)</graph>

            Above **P***, sellers offer more than buyers want, so prices fall; below it, shortages push prices up.
            """)
            after(1.5) {
                save("graph-chat.png", agent.debugSnapshot())
                agent.close()
                after(0.4) { print("GRAPHDEMO DONE"); exit(0) }
            }
        }
        app.run()
        exit(0)
    }

    /// `Margin --summarydemo <dir>`: a chat on a passage → the Summarize button → its two choices → each summary
    /// (real Claude calls), saving a snapshot at every step.
    static func summaries(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        let passage = """
        Opportunity cost is the value of the next-best alternative you give up when you make a choice. Because \
        resources such as time, money and labor are scarce, every decision involves a trade-off: spending an evening \
        studying means not spending it working a paid shift, so the forgone wages are part of the real cost of \
        studying. Economists argue that rational decision-makers weigh marginal benefits against marginal costs, \
        including these hidden opportunity costs, rather than looking only at explicit, out-of-pocket expenses. This \
        is why a "free" concert ticket still has a cost (the time you could have used elsewhere) and why firms \
        compare a project's return with what the same money could earn in the next-best project.
        """
        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 560, y: screen.visibleFrame.maxY - 140)
        func open() -> AskPanelController? {
            dock.open(Selection(text: passage, appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: point),
                      iconFrame: NSRect(x: point.x, y: point.y - 26, width: 26, height: 26))
            return dock.debugAgents.last
        }
        func waitDone(_ agent: AskPanelController, _ tries: Int = 240, then: @escaping () -> Void) {
            if agent.phase == .done || agent.phase == .failed || tries == 0 { after(1.2, then) }
            else { after(0.5) { waitDone(agent, tries - 1, then: then) } }
        }
        guard let first = open() else { print("SUMMARYDEMO FAIL"); exit(1) }
        after(0.8) {
            save("summary-1-chips.png", first.debugSnapshot())
            first.debugChooseSummary()
            after(0.6) {
                save("summary-2-choices.png", first.debugSnapshot())
                first.debugSummarize(.keywords)
                waitDone(first) {
                    save("summary-3-keywords.png", first.debugSnapshot())
                    print("  keywords: \(first.phase)")
                    first.close()
                    after(0.6) {
                        guard let second = open() else { exit(1) }
                        after(0.8) {
                            second.debugSummarize(.meaning)
                            waitDone(second) {
                                save("summary-4-meaning.png", second.debugSnapshot())
                                print("  meaning: \(second.phase)")
                                second.close()
                                after(0.4) { print("SUMMARYDEMO DONE"); exit(0) }
                            }
                        }
                    }
                }
            }
        }
        app.run()
        exit(0)
    }

    static func voice(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }

        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 560, y: screen.visibleFrame.maxY - 140)
        let selection = Selection(text: "Я закрыл дверь на замок.", appName: "Safari",
                                  context: ContextBox(resolved: nil), pid: 0, mouse: point)
        dock.open(selection, iconFrame: NSRect(x: point.x, y: point.y - 26, width: 26, height: 26))
        guard let agent = dock.debugAgents.first else { print("VOICEDEMO FAIL"); exit(1) }
        after(0.6) {
            agent.debugInject(question: "How do I pronounce this? Say it for me.", answer: """
            Here it is, stressed on the second syllable:

            <say lang="ru-RU" ipa="zɐˈmok">замо́к</say>

            The first **о** isn't stressed, so it shrinks to a quick "uh": *zuh-MOHK*. Stress the first syllable \
            instead (**за́мок**) and it means "castle".
            """)
            after(2.0) {
                save("voice-1-ready.png", agent.debugSnapshot())
                agent.debugSpeech.debugClips.first?.debugSetProgress(0.45)
                after(0.4) {
                    save("voice-2-midplay.png", agent.debugSnapshot())
                    agent.close()
                    after(0.4) { print("VOICEDEMO DONE"); exit(0) }
                }
            }
        }
        app.run()
        exit(0)
    }

    static func run(outputDirectory: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        AskPanelController.demoMode = true
        let dir = URL(fileURLWithPath: outputDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let dock = AgentDock()
        let screen = NSScreen.screens.first { $0.isBuiltIn } ?? NSScreen.main!
        let point = NSPoint(x: screen.visibleFrame.maxX - 560, y: screen.visibleFrame.maxY - 140)
        let selection = Selection(text: "closures capture variables by reference, not by value",
                                  appName: "Claude", context: ContextBox(resolved: nil), pid: 0, mouse: point)
        dock.open(selection, iconFrame: NSRect(x: point.x, y: point.y - 26, width: 26, height: 26))
        guard let agent = dock.debugAgents.first else { fail("no agent opened") }

        func save(_ name: String, _ image: CGImage?) {
            guard let image else { return print("  (no image for \(name))") }
            let url = dir.appendingPathComponent(name)
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
            print("  saved \(name) \(image.width)x\(image.height)")
        }
        func saveBubble(_ name: String) {
            guard let rep = dock.debugSidebar.debugSnapshot() else { return print("  (no sidebar)") }
            try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        func after(_ s: Double, _ f: @escaping () -> Void) { DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: f) }
        func fail(_ m: String) -> Never { print("DEMO FAIL: \(m)"); exit(1) }

        func savePNG(_ name: String, _ rep: NSBitmapImageRep?) {
            guard let rep, let png = rep.representation(using: .png, properties: [:]) else { return print("  (no \(name))") }
            try? png.write(to: dir.appendingPathComponent(name))
            print("  saved \(name) \(rep.pixelsWide)x\(rep.pixelsHigh)")
        }
        /// Several moments of an animation, side by side.
        func strip(_ frames: [NSBitmapImageRep]) -> NSBitmapImageRep? {
            guard let first = frames.first,
                  let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: first.pixelsWide * frames.count,
                                             pixelsHigh: first.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                                             hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                             bytesPerRow: 0, bitsPerPixel: 0),
                  let ctx = NSGraphicsContext(bitmapImageRep: out) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ctx
            for (i, f) in frames.enumerated() {
                f.draw(in: NSRect(x: i * first.pixelsWide, y: 0, width: first.pixelsWide, height: first.pixelsHigh))
            }
            NSGraphicsContext.restoreGraphicsState()
            return out
        }

        savePNG("0-trigger.png", TriggerIcon.debugRender())
        // The painted check up close, on the circle's dark color.
        if let check = BrushCheck.image(side: 200, scale: 2, color: Theme.ivory),
           let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
           let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext {
            ctx.setFillColor(NSColor(white: 0.09, alpha: 1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
            ctx.draw(check, in: CGRect(x: 0, y: 0, width: 400, height: 400))
            savePNG("0b-brush-check-large.png", rep)
        }
        print("1 open"); after(0.8) {
            save("1-open.png", agent.debugSnapshot())
            print("2 ask"); agent.debugAsk("What does 'by reference' mean here? Check the web.")
            after(0.9) {
                save("2-thinking.png", agent.debugSnapshot())
                print("3 minimize (phase: \(agent.phase))"); dock.debugMinimize(agent)
                after(1.0) {
                    saveBubble("3-bubble-working.png")
                    var frames: [NSBitmapImageRep] = []
                    func grab(_ n: Int, then next: @escaping () -> Void) {
                        if let f = dock.debugSidebar.debugSnapshot() { frames.append(f) }
                        if n > 1 { after(0.8) { grab(n - 1, then: next) } } else { next() }
                    }
                    func waitDone(_ tries: Int) {
                        if agent.phase == .done || agent.phase == .failed || tries == 0 {
                            after(1.0) {
                                saveBubble("4-bubble-\(agent.phase).png")
                                // Replay the finish and catch it mid-flight.
                                var doneFrames: [NSBitmapImageRep] = []
                                dock.debugSidebar.debugFlashAll()
                                for (i, t) in [0.08, 0.3, 0.55, 1.2].enumerated() {
                                    after(t) {
                                        if let f = dock.debugSidebar.debugSnapshot() { doneFrames.append(f) }
                                        if i == 3 { savePNG("4b-done-frames.png", strip(doneFrames)) }
                                    }
                                }
                            }
                            after(2.6) {
                                print("5 expand"); dock.debugExpand(agent)
                                after(1.2) {
                                    save("5-expanded.png", agent.debugSnapshot())
                                    print("frame after expand: \(agent.debugFrame)")
                                    print("6 make bigger"); agent.debugToggleSize()
                                    after(1.0) {
                                        save("6-large.png", agent.debugSnapshot())
                                        print("frame when large: \(agent.debugFrame)")
                                        agent.debugToggleSize()
                                        after(1.0) {
                                            print("frame back to normal: \(agent.debugFrame)")
                                            agent.close()
                                            after(0.5) { print("DEMO DONE"); exit(0) }
                                        }
                                    }
                                }
                            }
                        } else { after(0.5) { waitDone(tries - 1) } }
                    }
                    grab(4) {
                        savePNG("3b-working-frames.png", strip(frames))
                        waitDone(80)
                    }
                }
            }
        }
        app.run()
        exit(0)
    }
}
