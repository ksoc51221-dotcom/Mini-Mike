import AppKit
import Foundation
import SwiftUI
import WebKit

extension FeatureTests {
    /// Teaching visuals (the Visual menu): SVG clean-up, the scene check, the <visual> tag, where files go, the one-shot
    /// call's arguments, and the job flow with a fake model and a fake renderer. Never calls Claude or Manim.
    static func teachVisualChecks(_ check: (String, Bool) -> Void) {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("merlin-visuals-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: dir) }

        // MARK: SVG
        let reply = """
        Here you go:
        ```svg
        <?xml version="1.0"?>
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 960 540" width="960" height="540" onload="alert(1)">
          <title id="v-title">Forces</title>
          <defs><marker id="arrow-blue"><path d="M0 0 L10 5 L0 10z" fill="#58C4DD"/></marker></defs>
          <script>alert(1)</script>
          <foreignObject width="10" height="10"><div xmlns="http://www.w3.org/1999/xhtml">hi</div></foreignObject>
          <rect width="960" height="540" fill="#0f1117" onclick="x()"/>
          <use href="#arrow-blue"/>
          <use xlink:href="https://evil.example/x.svg#a"/>
          <a href="https://evil.example">link</a>
          <image href="https://evil.example/p.png"/>
          <rect style="fill:url(https://evil.example/f)" width="1" height="1"/>
          <line x1="0" y1="0" x2="10" y2="0" stroke="#58C4DD" marker-end="url(#arrow-blue)"/>
          <text x="40" y="52" fill="#FFFFFF">Weight &amp; normal</text>
        </svg>
        ```
        """
        let svg = TeachVisuals.extractSVG(reply) ?? ""
        let lower = svg.lowercased()
        check("visual svg: found in a fence and kept its drawing", lower.hasPrefix("<svg") && svg.contains("Weight &amp; normal") && svg.contains("<title"))
        check("visual svg: <script>, <foreignObject> and <image> removed",
              !lower.contains("<script") && !lower.contains("foreignobject") && !lower.contains("<image") && !lower.contains("alert"))
        check("visual svg: on…= attributes removed", !lower.contains("onload") && !lower.contains("onclick"))
        check("visual svg: external hrefs and url() removed, #… kept",
              !lower.contains("evil.example") && svg.contains("href=\"#arrow-blue\"") && svg.contains("url(#arrow-blue)"))
        check("visual svg: scales to its box (100% with the viewBox)", svg.contains("viewBox=\"0 0 960 540\"") && svg.contains("width=\"100%\""))
        check("visual svg: broken XML or a non-SVG root is refused",
              TeachVisuals.extractSVG("```svg\n<svg><g></svg>\n```") == nil && TeachVisuals.extractSVG("```svg\n<html><body/></html>\n```") == nil
              && TeachVisuals.extractSVG("No picture today.") == nil)
        let entity = "```svg\n<!DOCTYPE svg [<!ENTITY x SYSTEM \"file:///etc/passwd\">]>\n<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 10 10\"><text>&x;</text></svg>\n```"
        check("visual svg: a DOCTYPE with entities never reads a file", !(TeachVisuals.extractSVG(entity) ?? "").contains("root:"))
        check("visual svg: aspect from the viewBox", abs(TeachVisuals.svgAspect(svg) - 960.0 / 540.0) < 0.001 && TeachVisuals.svgAspect("<svg/>") == 16 / 9)

        // MARK: Python
        let scene = """
        from manim import *
        import numpy as np
        import math

        class TeachScene(Scene):
            def construct(self):
                dot = Dot(color=BLUE)
                pos = dot.get_center()
                self.play(Create(dot))  # evaluate the position: pos.x
                self.wait(1)
        """
        check("visual python: found in a ```python fence", TeachVisuals.extractPython("Sure.\n```python\n\(scene)\n```\nDone.") == scene)
        check("visual python: a clean scene passes (pos. and 'evaluate' are fine)", TeachVisuals.checkScene(scene) == nil)
        let harmless = scene + """

                c = math.cos(0.5)
                cos = c
                print(cos.real, pos.x)  # evaluate the camera
                self.camera.background_color = "#0f1117"
                self.add(Text("open the door"), Text("Watch the videos."), Text('eval and exec are just words'))
        """
        check("visual python: pos., cos., evaluate, self.camera and words in labels pass (\(TeachVisuals.checkScene(harmless) ?? "ok"))",
              TeachVisuals.checkScene(harmless) == nil)
        check("visual python: the word import inside a label is fine",
              TeachVisuals.checkScene(scene + "\n        self.add(Text(\"import tariffs\"))") == nil)
        let bad: [(String, String)] = [
            ("import os", "import os\n" + scene),
            ("from os import", scene.replacingOccurrences(of: "import math", with: "from os import path")),
            ("import after ;", scene.replacingOccurrences(of: "import math", with: "import math; import subprocess")),
            ("subprocess", scene + "\n        subprocess.run(['ls'])"),
            ("open(", scene + "\n        open('x').read()"),
            ("eval", scene + "\n        eval('1')"),
            ("exec", scene + "\n        exec('1')"),
            ("__import__", scene + "\n        __import__('os')"),
            ("os.", scene + "\n        os.remove('x')"),
            ("sys.", scene + "\n        sys.exit()"),
            ("importlib", scene.replacingOccurrences(of: "import math", with: "import importlib")),
            ("pathlib", scene + "\n        p = pathlib"),
            ("shutil", scene + "\n        shutil"),
            ("socket", scene + "\n        socket"),
            ("if 1: import", scene + "\n        if 1: import ctypes"),
            ("try: import", scene + "\n        try: import urllib.request\n        except: pass"),
            ("indented import", scene + "\n        import urllib"),
            ("getattr", scene + "\n        f = getattr(self, 'x')"),
            ("globals", scene + "\n        g = globals()"),
            ("compile", scene + "\n        c = compile('1', 'x', 'single')"),
            ("ctypeslib", scene + "\n        lib = np.ctypeslib"),
            ("builtins", scene + "\n        b = __builtins__"),
            ("builtins module", scene + "\n        b = np.builtins"),
            ("eval in an f-string", scene + "\n        t = Text(f\"{eval('1')}\")"),
            ("wrong class name", scene.replacingOccurrences(of: "TeachScene", with: "Other")),
            ("no manim import", scene.replacingOccurrences(of: "from manim import *", with: "")),
        ]
        let rejected = bad.filter { TeachVisuals.checkScene($0.1) == nil }.map(\.0)
        check("visual python: denied imports and calls are rejected (\(rejected.joined(separator: ", ")))", rejected.isEmpty)

        // MARK: The <visual> tag
        let answer = "A ball speeds up because gravity pulls it.\n\n<visual kind=\"diagram\" file=\"1.svg\"/>\n\n<visual kind=\"video\" file=\"2.mp4\"/>"
        let pieces = Answer.pieces(answer)
        check("visual tag: parsed into pieces after the text",
              pieces == [.text("A ball speeds up because gravity pulls it.\n\n"), .visual(.diagram, "1.svg"), .visual(.video, "2.mp4")]
              || (pieces.count == 3 && pieces[1] == .visual(.diagram, "1.svg") && pieces[2] == .visual(.video, "2.mp4")))
        let shown = pieces.compactMap { if case .text(let t) = $0 { return t } else { return nil } }.joined()
        check("visual tag: never shown as text", !shown.contains("<visual") && !Answer.plainText(answer).contains("<visual")
              && !Answer.noteMarkup(answer).contains("<visual") && Answer.plainText(answer) == "A ball speeds up because gravity pulls it.")
        // Every reader of a stored answer: transcript (copy, search), list snippet, naming digest, notes, the MCP export.
        let tagged = ChatRecord(id: UUID(), title: "Tagged", sector: "Physics", app: "", quote: "", turns: [.init(question: "Why?", answer: answer)])
        let readers = [tagged.transcript, tagged.snippet, ChatNaming.digest(tagged), SheetActions.markup(fromAnswer: answer),
                       Answer.noteMarkup(answer), Answer.plainText(answer)]
        check("visual tag: no reader of a stored answer leaks the tag or its file name",
              readers.allSatisfy { !$0.contains("<visual") && !$0.contains("1.svg") && !$0.contains("2.mp4") })
        let unsafe = ["<visual kind=\"diagram\" file=\"../x.svg\"/>", "<visual kind=\"diagram\" file=\"1.mp4\"/>",
                      "<visual kind=\"video\" file=\"/etc/x.mp4\"/>", "<visual kind=\"html\" file=\"1.svg\"/>", "<visual file=\"1.svg\"/>"]
        check("visual tag: unsafe or mismatched tags are dropped, not shown",
              unsafe.allSatisfy { tag in Answer.pieces("Hi " + tag).allSatisfy { if case .text(let t) = $0 { return !t.contains("<visual") } else { return false } } })
        check("visual tag: Merlin's own markup round-trips",
              Answer.pieces(Answer.visualMarkup(kind: .video, file: "3.mp4")) == [.visual(.video, "3.mp4")])
        check("visual tag: a half-written tag is hidden while streaming",
              !Answer.pieces("Text <visu", hidePartial: true).contains { if case .text(let t) = $0 { return t.contains("<visu") } else { return false } })
        check("visual tag: answers without one are unchanged",
              Answer.pieces("Plain <say>hi</say> words") == Answer.pieces("Plain <say>hi</say> words", hidePartial: false))

        // MARK: Files
        let chat = UUID()
        let folder = TeachVisuals.folder(chat: chat, library: dir)
        check("visual files: <Library>/Visuals/<chat-id>", folder.path == dir.appendingPathComponent("Visuals/\(chat.uuidString)").path)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        check("visual files: numbering starts at 1", TeachVisuals.nextNumber(in: folder) == 1)
        for name in ["1.svg", "2.py", "4.mp4", "notes.txt"] { fm.createFile(atPath: folder.appendingPathComponent(name).path, contents: Data()) }
        check("visual files: the next number follows the highest", TeachVisuals.nextNumber(in: folder) == 5)

        let libDir = dir.appendingPathComponent("lib", isDirectory: true)
        let library = Library(directory: libDir)
        let rec = ChatRecord(id: UUID(), title: "Gravity", sector: "Physics", app: "Safari", quote: "", turns: [.init(question: "Q", answer: "A")])
        library.save(rec)
        let recFolder = TeachVisuals.folder(chat: rec.id, library: libDir)
        try? fm.createDirectory(at: recFolder, withIntermediateDirectories: true)
        fm.createFile(atPath: recFolder.appendingPathComponent("1.svg").path, contents: Data("<svg/>".utf8))
        library.delete(chat: rec.id)
        library.flush()
        let keptInBin = fm.fileExists(atPath: recFolder.path)
        library.deleteForever(rec.id)
        library.flush()
        check("visual files: a binned chat keeps its visuals; deleting it for good removes them", keptInBin && !fm.fileExists(atPath: recFolder.path))
        let unsaved = UUID(), unsavedFolder = TeachVisuals.folder(chat: unsaved, library: libDir)
        let kept = ChatRecord(id: UUID(), title: "Kept", sector: "Physics", app: "", quote: "", turns: [.init(question: "Q", answer: "A")])
        library.save(kept)
        let keptFolder = TeachVisuals.folder(chat: kept.id, library: libDir)
        for f in [unsavedFolder, keptFolder] { try? fm.createDirectory(at: f, withIntermediateDirectories: true) }
        TeachVisuals.removeIfUnsaved(chat: unsaved, library: library)
        TeachVisuals.removeIfUnsaved(chat: kept.id, library: library)
        check("visual files: closing a never-saved chat removes its folder; a saved chat's stays",
              !fm.fileExists(atPath: unsavedFolder.path) && fm.fileExists(atPath: keptFolder.path))

        // MARK: The web view's offline rule and PNG export (no view is made)
        let storeDir = dir.appendingPathComponent("rules", isDirectory: true)
        try? fm.createDirectory(at: storeDir, withIntermediateDirectories: true)
        var compiled: Bool?
        if let store = WKContentRuleListStore(url: storeDir) {
            store.compileContentRuleList(forIdentifier: "test", encodedContentRuleList: TeachVisualActions.blockRules) { list, _ in compiled = list != nil }
            pump(10) { compiled != nil }
        }
        check("visual web view: the block-everything-but-files rule compiles", compiled == true)
        let svgFile = folder.appendingPathComponent("9.svg")
        try? Data(svg.utf8).write(to: svgFile)
        if let png = TeachVisualActions.pngData(svg: svgFile), let rep = NSBitmapImageRep(data: png) {
            // The background rect is #0f1117; the blue line and white text are not. Look for any brighter pixel.
            var bright = false
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) where !bright {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    if let c = rep.colorAt(x: x, y: y), c.brightnessComponent > 0.5 { bright = true; break }
                }
            }
            check("visual png: 1920 px wide and the drawing shows (not just background)", rep.pixelsWide == 1920 && rep.pixelsHigh == 1080 && bright)
        } else {
            check("visual png: 1920 px wide and the drawing shows (not just background)", false)
        }

        // MARK: The one-shot call
        let args = ClaudeOneShot.launchArguments(system: "S", model: .sonnet, effort: TeachVisuals.Kind.diagram.effort)
        func pair(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        check("visual call: Sonnet, no tools, no settings files (no skills), no MCP, effort low/medium",
              pair("--model") == "sonnet" && pair("--tools") == "" && pair("--setting-sources") == "" && args.contains("--strict-mcp-config")
              && pair("--effort") == "low" && TeachVisuals.Kind.video.effort == "medium" && pair("--system-prompt") == "S")
        check("visual call: the prompt has the highlight, question and answer, trimmed",
              { let p = TeachVisuals.prompt(selection: String(repeating: "s", count: 5_000), question: "Why?", answer: "Because.")
                return p.contains("Why?") && p.contains("Because.") && p.count < 2_500 }())
        check("visual briefs: about 1.5–2.5k tokens, one fenced block, LaTeX only when installed",
              (5_500...10_500).contains(TeachBriefs.diagram.count) && (5_500...10_500).contains(TeachBriefs.manim(latex: false).count)
              && TeachBriefs.manim(latex: false).contains("LaTeX is NOT installed") && TeachBriefs.manim(latex: true).contains("LaTeX is installed")
              && TeachBriefs.manim(latex: false).contains("TeachScene"))

        // MARK: Render command
        let rArgs = TeachVisuals.renderArguments(.init(manim: "/x/manim", folder: folder, number: 3), jobPath: "/job", home: "/Users/x")
        check("visual render: sandboxed, fixed arguments",
              rArgs.first == "-p" && rArgs[1] == TeachVisuals.sandboxProfile && rArgs[2...6] == ["-D", "JOB=/job", "-D", "HOME=/Users/x", "/x/manim"]
              && Array(rArgs.suffix(8)) == ["-ql", "--disable_caching", "--media_dir", "/job/media", "-o", "3.mp4", "3.py", "TeachScene"])
        check("visual render: the profile denies network and writes outside the job",
              TeachVisuals.sandboxProfile.contains("(deny network*)") && TeachVisuals.sandboxProfile.contains("(deny file-write*)")
              && TeachVisuals.sandboxProfile.contains("(param \"JOB\")") && TeachVisuals.sandboxProfile.contains("(deny process-exec*)")
              && TeachVisuals.sandboxProfile.contains("(deny file-read* (subpath (param \"HOME\")))")
              && TeachVisuals.sandboxProfile.contains("com.apple.coreservices.appleevents"))

        // MARK: Job flow with fakes
        let savedRun = TeachVisuals.claudeRun, savedRender = TeachVisuals.renderRun, savedFind = TeachVisuals.findManim
        defer { TeachVisuals.claudeRun = savedRun; TeachVisuals.renderRun = savedRender; TeachVisuals.findManim = savedFind }
        func run(_ kind: TeachVisuals.Kind, chat: UUID) -> (Result<String, TeachVisuals.Failure>?, [TeachVisuals.Stage]) {
            var result: Result<String, TeachVisuals.Failure>?
            var stages: [TeachVisuals.Stage] = []
            TeachVisuals.make(.init(kind: kind, chat: chat, library: dir, selection: "a ball", question: "Why?", answer: "Gravity."),
                              stage: { stages.append($0) }) { result = $0 }
            pump(5) { result != nil }
            return (result, stages)
        }

        // Manim missing: no model call at all.
        var calls: [String] = []
        TeachVisuals.findManim = { nil }
        TeachVisuals.claudeRun = { prompt, _, _, done in calls.append(prompt); done(fakeReply("```python\n\(scene)\n```")) }
        let (missing, _) = run(.video, chat: UUID())
        check("visual manim: not installed → message with the install command, no Claude call",
              missing == .failure(.manimMissing) && calls.isEmpty && TeachVisuals.Failure.manimMissing.message.contains("uv tool install manim"))

        // Diagram.
        let diagramChat = UUID()
        TeachVisuals.claudeRun = { prompt, system, kind, done in
            calls.append(prompt)
            done(kind == .diagram && system == TeachBriefs.diagram ? fakeReply(reply) : fakeReply("nope"))
        }
        let (dResult, dStages) = run(.diagram, chat: diagramChat)
        let saved = (try? String(contentsOf: TeachVisuals.folder(chat: diagramChat, library: dir).appendingPathComponent("1.svg"), encoding: .utf8)) ?? ""
        check("visual diagram: one call, cleaned file saved as 1.svg", dResult == .success("1.svg") && dStages == [.writingDiagram]
              && calls.count == 1 && saved.hasPrefix("<svg") && !saved.contains("script"))

        // Video: the render fails once, the fix renders.
        calls = []
        var renders: [TeachVisuals.RenderRequest] = []
        TeachVisuals.findManim = { "/fake/manim" }
        TeachVisuals.claudeRun = { prompt, _, kind, done in calls.append(prompt); done(kind == .video ? fakeReply("```python\n\(scene)\n```") : fakeReply("")) }
        TeachVisuals.renderRun = { r, _, _ in
            renders.append(r)
            if renders.count == 1 { return .failed("Traceback\nNameError: name 'Foo' is not defined") }
            let url = r.folder.appendingPathComponent("\(r.number).mp4")
            FileManager.default.createFile(atPath: url.path, contents: Data("mp4".utf8))
            return .video(url)
        }
        let videoChat = UUID()
        let (vResult, vStages) = run(.video, chat: videoChat)
        check("visual video: a failed render sends the error back once, then the fix renders",
              vResult == .success("2.mp4") && calls.count == 2 && renders.count == 2 && renders.map(\.number) == [1, 2]
              && calls[1].contains("NameError: name 'Foo' is not defined") && calls[1].contains(TeachBriefs.fixRequest)
              && vStages == [.writingScene, .rendering, .fixingScene, .rendering])

        // Video: it fails twice → stop with an error (two model calls at most).
        calls = []; renders = []
        TeachVisuals.renderRun = { r, _, _ in renders.append(r); return .failed("ValueError: bad") }
        let (failed, _) = run(.video, chat: UUID())
        if case .failure(.render(let m)) = failed {
            check("visual video: a second failure stops with an error", calls.count == 2 && renders.count == 2 && m.contains("ValueError"))
        } else { check("visual video: a second failure stops with an error", false) }

        // Video: a rejected script uses the same single fix.
        calls = []; renders = []
        TeachVisuals.claudeRun = { prompt, _, _, done in calls.append(prompt); done(fakeReply("```python\nimport os\n\(scene)\n```")) }
        let (rejectedRun, _) = run(.video, chat: UUID())
        check("visual video: a rejected scene gets one fix, never runs", calls.count == 2 && renders.isEmpty
              && { if case .failure(.badReply) = rejectedRun { return true } else { return false } }())

        // Cancel during the model call: the late reply is ignored.
        var pending: ((Result<ClaudeOneShot.Reply, ClaudeOneShot.Failure>) -> Void)?
        TeachVisuals.claudeRun = { _, _, _, done in pending = done }
        var cancelResult: Result<String, TeachVisuals.Failure>?
        let cancelChat = UUID()
        let handle = TeachVisuals.make(.init(kind: .diagram, chat: cancelChat, library: dir, selection: "", question: "Q", answer: "A"),
                                       stage: { _ in }) { cancelResult = $0 }
        handle.cancel()
        pending?(fakeReply(reply))
        pump(3) { cancelResult != nil }
        check("visual cancel: a late reply saves nothing", cancelResult == .failure(.cancelled)
              && !fm.fileExists(atPath: TeachVisuals.folder(chat: cancelChat, library: dir).appendingPathComponent("1.svg").path))
    }

    /// `Merlin --visualsandboxtest`: a fixed scene (it skips `checkScene` on purpose) runs through `TeachVisuals.render` and
    /// tries to escape: read Merlin's Library and ~/.ssh, write outside the job folder, open a socket, and run
    /// `/usr/bin/open -g https://example.com`. Each attempt writes "blocked" or "ALLOWED" into the job folder; every one
    /// must be blocked, and the scene must still render. Headless; nothing is printed from the files it tried to read.
    static func visualSandboxTest() -> Never {
        guard let manim = TeachVisuals.findManim() else { print("FAIL manim not found"); exit(1) }
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let folder = home.appendingPathComponent("Library/Caches/merlin visual sandboxtest \(UUID().uuidString)", isDirectory: true)
        let escape = home.appendingPathComponent("Library/Caches/merlin-sandbox-escape-\(UUID().uuidString).txt")
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func end(_ code: Int32) -> Never { try? fm.removeItem(at: folder); try? fm.removeItem(at: escape); exit(code) }
        let library = ClaudeSession.workingDirectory.appendingPathComponent("Library", isDirectory: true).path
        let scene = """
        from manim import *
        import os, socket, subprocess

        LIB = \(String(reflecting: library))
        SSH = os.path.join(os.path.expanduser("~"), ".ssh")
        RESULTS = os.path.join(os.getcwd(), "results.txt")

        def attempt(name, fn):
            try:
                fn()
                r = "ALLOWED"
            except Exception as e:
                r = "blocked " + type(e).__name__
            with open(RESULTS, "a") as f:
                f.write(name + ": " + r + "\\n")

        def read_first(d):
            names = sorted(os.listdir(d))
            for n in names:
                p = os.path.join(d, n)
                if os.path.isfile(p):
                    open(p, "rb").read(1)
                    return

        def write_outside():
            with open(\(String(reflecting: escape.path)), "w") as f:
                f.write("escaped")

        def net():
            socket.create_connection(("93.184.215.14", 80), timeout=3).close()

        def launch():
            subprocess.run(["/usr/bin/open", "-g", "https://example.com"], check=True, timeout=5)

        class TeachScene(Scene):
            def construct(self):
                attempt("read Merlin library", lambda: read_first(LIB))
                attempt("read ~/.ssh", lambda: read_first(SSH))
                attempt("write outside job", write_outside)
                attempt("socket", net)
                attempt("run /usr/bin/open", launch)
                self.add(Circle(color=BLUE))
                self.wait(0.2)
        """
        try? Data(scene.utf8).write(to: folder.appendingPathComponent("1.py"))
        let outcome = TeachVisuals.render(.init(manim: manim, folder: folder, number: 1), handle: TeachVisuals.CancelHandle())
        let results = (try? String(contentsOf: folder.appendingPathComponent("results.txt"), encoding: .utf8)) ?? ""
        let lines = results.split(separator: "\n").map(String.init)
        var failed = false
        for line in lines { let ok = line.contains(": blocked"); failed = failed || !ok; print((ok ? "ok   sandbox: " : "FAIL sandbox: ") + line) }
        if lines.count != 5 { failed = true; print("FAIL sandbox: expected 5 results, got \(lines.count)") }
        if fm.fileExists(atPath: escape.path) { failed = true; print("FAIL sandbox: the outside file exists") }
        if case .video = outcome { print("ok   sandbox: the scene still rendered") } else { failed = true; print("FAIL sandbox: render \(outcome)") }
        end(failed ? 1 : 0)
    }

    /// `Merlin --visualshots <svg> <dir>`: offscreen pictures (no window): the chat with a diagram under the answer and
    /// the Visual menu button, plus the web view's own snapshot. Also checks that the web view loads nothing when the
    /// offline rule fails to compile.
    @MainActor static func visualShots(svg: String, directory: String) -> Never {
        _ = NSApplication.shared
        Motion.still = true
        let fm = FileManager.default
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try? fm.createDirectory(at: out, withIntermediateDirectories: true)
        let lib = fm.temporaryDirectory.appendingPathComponent("merlin-visualshots-\(UUID().uuidString)", isDirectory: true)
        Library.overrideDirectory = lib
        func end(_ code: Int32) -> Never { try? fm.removeItem(at: lib); exit(code) }
        let chat = UUID()
        let folder = TeachVisuals.folder(chat: chat, library: lib)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? fm.copyItem(at: URL(fileURLWithPath: svg), to: folder.appendingPathComponent("1.svg"))) != nil else {
            print("FAIL could not copy \(svg)"); end(1)
        }
        var failed = false
        func save(_ rep: NSBitmapImageRep?, _ name: String) {
            let file = out.appendingPathComponent(name)
            if let data = rep?.representation(using: .png, properties: [:]), (try? data.write(to: file)) != nil {
                print("ok   \(file.path)")
            } else { failed = true; print("FAIL \(name)") }
        }
        func pump(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        // 1. Fail closed: with a rule list WebKit refuses, nothing loads.
        let goodRules = TeachVisualActions.blockRules
        TeachVisualActions.blockRules = "not json"
        let closedHost = NSHostingView(rootView: SVGWebView(url: folder.appendingPathComponent("1.svg"), readAccess: folder))
        closedHost.frame = NSRect(x: 0, y: 0, width: 480, height: 270)
        closedHost.layoutSubtreeIfNeeded()
        pump(3)
        let closedWeb = closedHost.firstWebView
        print((closedWeb != nil && closedWeb?.url == nil ? "ok   " : "FAIL ") + "web view loads nothing when the rule list fails to compile (url: \(closedWeb?.url?.absoluteString ?? "nil"))")
        if !(closedWeb != nil && closedWeb?.url == nil) { failed = true }
        TeachVisualActions.blockRules = goodRules

        // 2. The chat: answer, diagram, the Visual button.
        let selection = Selection(text: "projectile motion", appName: "Safari", context: ContextBox(resolved: nil), pid: 0, mouse: .zero)
        let model = AskModel(selection: selection, footnote: "Sonnet")
        model.chatID = chat
        model.turns = [AskModel.Turn(question: "Why are the two motions independent?",
                                     answer: "Gravity acts only downwards, so the horizontal velocity stays constant.\n\n"
                                        + Answer.visualMarkup(kind: .diagram, file: "1.svg"), done: true)]
        for (name, appearance, scheme) in [("dark", NSAppearance(named: .darkAqua)!, ColorScheme.dark), ("light", NSAppearance(named: .aqua)!, ColorScheme.light)] {
            NSApp.appearance = appearance
            let host = NSHostingView(rootView: AskView(model: model).frame(width: 520, height: 640).environment(\.colorScheme, scheme))
            host.appearance = appearance
            host.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
            host.settleLayout(passes: 4, interval: 0.12)
            pump(3) // the web view loads in its own process
            host.settleLayout(passes: 2, interval: 0.1)
            save(host.snapshotRep(), "chat-visual-\(name).png")
            if name == "dark" {
                // The real chat width (380), with and without the Visual button, to compare the follow-up row.
                for (label, id) in [("with-visual", chat as UUID?), ("without-visual", nil)] {
                    model.chatID = id
                    let w = AskPanelController.width
                    let narrow = NSHostingView(rootView: AskView(model: model).frame(width: w, height: 640).environment(\.colorScheme, scheme))
                    narrow.appearance = appearance
                    narrow.frame = NSRect(x: 0, y: 0, width: w, height: 640)
                    narrow.settleLayout(passes: 4, interval: 0.12)
                    save(narrow.snapshotRep(), "chat-380-\(label).png")
                }
                model.chatID = chat
            }
            // The web view's own picture (WebKit draws out of process, so the host snapshot may show it blank).
            if let web = host.firstWebView {
                var image: NSImage?
                var done = false
                web.takeSnapshot(with: nil) { img, _ in image = img; done = true }
                let until = Date().addingTimeInterval(5)
                while !done, Date() < until { pump(0.05) }
                save(image.flatMap { $0.tiffRepresentation }.flatMap(NSBitmapImageRep.init(data:)), "webview-snapshot-\(name).png")
            } else { failed = true; print("FAIL no web view in the chat") }
        }
        end(failed ? 1 : 0)
    }

    /// `Merlin --visualrendertest`: one real, sandboxed Manim render of a tiny fixed scene through `TeachVisuals.render`.
    /// Headless: no window. The job folder is outside the temp folders, so the sandbox's JOB rule is what allows the writes.
    static func visualRenderTest() -> Never {
        guard let manim = TeachVisuals.findManim() else { print("FAIL manim not found: \(TeachVisuals.notInstalledMessage)"); exit(1) }
        let fm = FileManager.default
        let folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/merlin visual rendertest \(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        func end(_ code: Int32) -> Never { try? fm.removeItem(at: folder); exit(code) }
        let scene = """
        from manim import *

        class TeachScene(Scene):
            def construct(self):
                c = Circle(color="#58C4DD")
                t = Text("Merlin", color="#FFFF00", font_size=40)
                self.play(Create(c), Write(t), run_time=1)
                self.wait(0.5)
        """
        guard TeachVisuals.checkScene(scene) == nil else { print("FAIL the fixed scene fails the check"); end(1) }
        try? Data(scene.utf8).write(to: folder.appendingPathComponent("1.py"))
        let start = Date()
        let outcome = TeachVisuals.render(.init(manim: manim, folder: folder, number: 1), handle: TeachVisuals.CancelHandle())
        let secs = String(format: "%.1f", Date().timeIntervalSince(start))
        guard case .video(let url) = outcome, let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 1_000 else {
            print("FAIL render: \(outcome)"); end(1)
        }
        let leftovers = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        print("ok   real sandboxed render: \(url.lastPathComponent), \(size) bytes, \(secs) s; folder now \(leftovers)")
        end(0)
    }
    /// `Merlin --visuallive <dir>`: real model calls (costs tokens) for one diagram and one video on a fixed physics
    /// question, saved under <dir>. Headless: no window.
    static func visualLiveTest(directory: String) -> Never {
        let dir = URL(fileURLWithPath: directory, isDirectory: true)
        let chat = UUID()
        let econ = ProcessInfo.processInfo.environment["VISUAL_TOPIC"] == "econ"
        let q = econ ? "What happens to price and quantity when demand rises?" : "Explain why the horizontal and vertical motion of a projectile are independent."
        let a = econ ? "When demand rises, the demand curve shifts right. At the old price there is now excess demand, so the price rises until a new equilibrium is reached: both the equilibrium price and the equilibrium quantity are higher. Suppliers respond by moving along the supply curve, not by shifting it." : "Gravity acts only downwards, so the horizontal velocity stays constant while the vertical velocity changes by 9.8 m/s every second. A ball thrown at 20 m/s at 30 degrees has ux = 17.3 m/s and uy = 10 m/s; it reaches its top after about 1.0 s and lands after about 2.0 s, about 35 m away."
        var failed = false
        // Print what each model call cost. The real runner still logs it to Merlin's usage.jsonl (UsageLog.url is not swapped here).
        let realRun = TeachVisuals.claudeRun
        TeachVisuals.claudeRun = { prompt, system, kind, done in
            realRun(prompt, system, kind) { result in
                if case .success(let r) = result {
                    let u = r.usage
                    print("     usage \(kind.why): input \(u.inputTokens), output \(u.outputTokens), cache read \(u.cacheReadTokens), "
                          + "cache write \(u.cacheCreationTokens), $\(String(format: "%.4f", u.costUSD)), \(String(format: "%.1f", u.apiSeconds)) s")
                }
                done(result)
            }
        }
        print("     usage log: \(UsageLog.url.path)")
        for kind in [TeachVisuals.Kind.diagram, .video] {
            var result: Result<String, TeachVisuals.Failure>?
            let start = Date()
            TeachVisuals.make(.init(kind: kind, chat: chat, library: dir, selection: "projectile motion", question: q, answer: a),
                              stage: { print("     stage: \($0.text)") }, done: { result = $0 })
            while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.2)) }
            let secs = Int(Date().timeIntervalSince(start))
            switch result! {
            case .success(let file): print("ok   live \(kind): \(TeachVisuals.folder(chat: chat, library: dir).appendingPathComponent(file).path) in \(secs) s")
            case .failure(let f): failed = true; print("FAIL live \(kind): \(f.message)")
            }
        }
        exit(failed ? 1 : 0)
    }
}

private extension NSView {
    /// The first WKWebView inside this view (for the offscreen pictures).
    var firstWebView: WKWebView? {
        if let w = self as? WKWebView { return w }
        for v in subviews { if let w = v.firstWebView { return w } }
        return nil
    }
}
