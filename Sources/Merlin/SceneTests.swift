import Foundation
import SceneKit

/// Package C: the <scene> 3D scene. Reading, trimming, clamping, falling back to text, streaming, stripping, the prompt
/// rule and its gate, and building the SceneKit nodes without a window.
extension FeatureTests {
    static func sceneChecks(_ check: (String, Bool) -> Void) {
        let atom = SceneSpec.atomSample, forces = SceneSpec.forcesSample

        // Good scenes read.
        let a = SceneSpec.parse(atom), f = SceneSpec.parse(forces)
        check("scene: the atom sample parses (5 parts, 3 on orbits around the nucleus)",
              a?.parts.count == 5 && a?.parts.filter { $0.orbit?.around == "n" }.count == 3)
        check("scene: the forces sample parses (a box, 4 arrows, 4 labels)",
              f?.parts.count == 9 && f?.parts.filter { $0.kind == .arrow }.count == 4 && f?.parts.filter { $0.kind == .label }.count == 4)
        check("scene: short and long keys read the same",
              SceneSpec.parse(#"{"parts":[{"id":"a","kind":"box","size":[1,2,3],"position":[1,2,3],"color":"green"}],"caption":"Hi."}"#)
                == SceneSpec.parse(#"{"p":[{"id":"a","k":"box","s":[1,2,3],"at":[1,2,3],"c":"green"}],"cap":"Hi."}"#))

        // Limits: trimmed, clamped, tolerant.
        let many = #"{"p":["# + (0..<20).map { #"{"k":"sphere","at":[\#($0 % 6),0,0]}"# }.joined(separator: ",") + "]}"
        check("scene: more than 12 parts is trimmed to 12, not rejected", SceneSpec.parse(many)?.parts.count == 12)
        let far = SceneSpec.parse(#"{"p":[{"k":"box","at":[99,-40,2.3],"s":500}]}"#)?.parts.first
        check("scene: places are clamped to −6…6 and snapped to halves", far?.x == 6 && far?.y == -6 && far?.z == 2.5)
        check("scene: sizes are clamped", far?.size == [SceneSpec.maxSize])
        let odd = SceneSpec.parse(#"{"p":[{"k":"sphere","c":"chartreuse"},{"k":"hexagon"},{"k":"cube","c":"Grey"},{"k":"label"}]}"#)
        check("scene: an unknown colour is neutral", odd?.parts.first?.colour == .neutral)
        check("scene: an unknown kind is dropped, an alias (cube) is a box, a label with no text is dropped",
              odd?.parts.map(\.kind) == [.sphere, .box])
        let nan = SceneSpec.parse(#"{"p":[{"k":"sphere","at":["nan","inf",1],"s":"-inf","spin":0,"o":{"r":"nan","t":-3}}]}"#)?.parts.first
        check("scene: NaN and infinity are dropped (place and size)", nan.map { $0.x == 0 && $0.y == 0 && $0.z == 1 && $0.size.isEmpty } == true)
        check("scene: periods are never zero or negative, and a NaN radius is replaced",
              nan.map { ($0.spin ?? 0) >= SceneSpec.minPeriod && ($0.orbit?.period ?? 0) >= SceneSpec.minPeriod && $0.orbit?.radius.isFinite == true } == true)
        let loop = SceneSpec.parse(#"{"p":[{"id":"a","k":"sphere","o":{"a":"b"}},{"id":"b","k":"sphere","o":{"a":"a"}},{"id":"c","k":"sphere","o":{"a":"c"}},{"id":"d","k":"sphere","o":{"a":"ghost"}}]}"#)
        check("scene: an orbit around a missing part, itself, or a ring of parts circles the origin",
              loop?.parts.filter { $0.orbit?.around != nil }.count ?? 9 <= 1 && loop?.parts[2].orbit?.around == nil && loop?.parts[3].orbit?.around == nil)
        let xyz = SceneSpec.parse(#"{"p":[{"k":"sphere","x":2,"y":"1","z":-3},{"k":"label","x":"Core","at":[0,1,0]}]}"#)?.parts
        check("scene: numeric x/y/z keys are a place; a word in x is a label's text",
              xyz?.first.map { $0.x == 2 && $0.y == 1 && $0.z == -3 && $0.text == nil } == true && xyz?.last?.text == "Core" && xyz?.last?.y == 1)
        check("scene: a zero arrow direction points up", SceneSpec.parse(#"{"p":[{"k":"arrow","d":[0,0,0]}]}"#)?.parts.first?.direction == [0, 1, 0])
        for (name, json) in [("not JSON", "{p: oops"), ("no parts", #"{"p":[]}"#), ("only unknown kinds", #"{"p":[{"k":"blob"}]}"#), ("a list", "[1,2]")] {
            check("scene check: \(name) is not a scene", SceneSpec.parse(json) == nil)
        }

        // A scene that fails shows as text: never raw JSON.
        func shown(_ pieces: [Answer.Piece]) -> String {
            pieces.map { p -> String in if case .text(let t) = p { return t } else { return "" } }.joined()
        }
        func hasScene(_ pieces: [Answer.Piece]) -> Bool { pieces.contains { if case .scene = $0 { return true } else { return false } } }
        let bad = Answer.pieces("Look:\n<scene>{\"p\":[{\"k\":oops</scene>\nThat's it.")
        check("scene fallback: bad JSON draws no scene and shows the text around it, with no JSON",
              !hasScene(bad) && shown(bad).contains("Look:") && shown(bad).contains("That's it.") && !shown(bad).contains("{") && !shown(bad).contains("scene"))
        let empty = Answer.pieces(#"Here:<scene>{"p":[{"k":"blob"}],"cap":"An idea in words."}</scene>"#)
        check("scene fallback: an empty scene shows its caption as text", !hasScene(empty) && shown(empty).contains("An idea in words.") && !shown(empty).contains("{"))
        check("scene fallback: a scene that never closed hides its JSON", !shown(Answer.pieces("So:\n<scene>{\"p\":[{\"k\"")).contains("{"))

        // Streaming: every prefix, both modes, never crashes and never shows JSON or the tag.
        let full = "An atom is mostly empty space.\n<scene>\(atom)</scene>\nThe nucleus holds almost all the mass."
        var leaked: [String] = []
        var index = full.startIndex
        while index <= full.endIndex {
            let prefix = String(full[..<index])
            for partial in [true, false] {
                let text = shown(Answer.pieces(prefix, hidePartial: partial)) + " " + Answer.plainText(prefix)
                if text.contains("{") || text.contains("\"p\"") || text.lowercased().contains("<scene") || text.contains("</") {
                    leaked.append(prefix)
                }
            }
            if index == full.endIndex { break }
            index = full.index(after: index)
        }
        check("scene streaming: no prefix of \(full.count) characters shows JSON or the tag", leaked.isEmpty)
        check("scene streaming: a half-written scene shows 'Building a 3D scene…'", Answer.pieces(String(full.prefix(80)), hidePartial: true).last == .buildingScene)
        let finished = Answer.pieces(full, hidePartial: true)
        check("scene streaming: the finished answer is text, scene, text", finished.count == 3 && hasScene(finished) && shown(finished).contains("almost all the mass"))
        check("scene: a scene in a ``` fence leaves no empty code block",
              Answer.pieces("See:\n```json\n<scene>\(atom)</scene>\n```\nDone.") == [.text("See:\n"), .scene(atom.trimmingCharacters(in: .whitespacesAndNewlines)), .text("\nDone.")])

        // Stripped from plain text (previews, titles, search, quiz and prompt input).
        let plain = Answer.plainText(full)
        check("scene plain text: no JSON or tag", !plain.contains("{") && !plain.lowercased().contains("<scene") && !plain.contains("\"k\""))
        check("scene plain text: keeps the caption and labels", plain.contains("[a 3D scene was shown here:") && plain.contains("dense nucleus") && plain.contains("Nucleus"))
        check("scene library: a chat's transcript has no scene JSON",
              { let r = ChatRecord(title: "t", sector: "Chemistry", app: "Safari", quote: "q", turns: [.init(question: "Show an atom", answer: full)]); return !r.transcript.contains("{") }())

        // The prompt rule: small, valid, and sent only when it can apply.
        let rule = Prompts.sceneRule
        check("scene rule: 90 tokens or fewer (\(rule.count) characters, about \(rule.count / 4) tokens)", rule.count <= 360)
        check("scene rule: its own example is a valid scene", Answer.pieces(rule).contains { if case .scene = $0 { return true } else { return false } })
        check("scene rule: says the limit and the kinds", rule.contains("≤12 parts") && rule.contains("torus") && rule.contains("label"))
        func gate(_ q: String, _ sel: String = "") -> Bool { Prompts.features(question: q, selection: sel).contains(.scene) }
        check("scene gate: 3D questions get it", ["show me a 3D model of an atom", "How do planets orbit the sun?", "What is the structure of a water molecule?",
                                                  "Draw the solar system", "What are the forces on a block on a slope?"].allSatisfy { gate($0) })
        check("scene gate: ordinary questions don't", !gate("what is inflation") && !gate("Why does a price ceiling cause a shortage?")
              && !gate("What does this mean?") && !gate("Explain this more simply.") && !gate("Define this word"))
        check("scene gate: Visualize gets it only when the highlight is 3D",
              gate(Prompts.visualize, "The carbon atom has six electrons.") && !gate(Prompts.visualize, "y = x^2") && !gate(Prompts.visualize))
        check("scene gate: Pronounce and quizzes never", !gate(Prompts.pronounce, "atom") && !gate(Prompts.quiz, "molecule"))
        check("scene gate: never part of .all", !Prompts.Features.all.contains(.scene))
        check("scene gate: the rule is in the prompt only with .scene",
              Prompts.system(webSearch: false, features: .scene).contains(rule) && !Prompts.system(webSearch: false, features: [.all, .board, .learn]).contains(rule))
        check("scene gate: the quick and local models never get it",
              !Prompts.quickSystem(seeing: true, model: Settings.haikuID, features: [.scene, .board, .learn, .graphs]).contains(rule) && !Prompts.localSystem.contains(rule))
        let later = Prompts.extraInstructions(for: "show me a 3D model of it", have: [])
        check("scene gate: a later 3D question carries the rule once", later?.added.contains(.scene) == true && later?.text.contains(rule) == true
              && Prompts.extraInstructions(for: "show me a 3D model of it", have: [.scene, .graphs, .board]) == nil)

        // Building the SceneKit tree, with no window.
        if let a {
            let still = SceneBuilder.partsNode(a, dark: true, animated: false)
            let parts = SceneBuilder.partNodes(in: still)
            check("scene nodes: one node for each part of the atom", parts.count == 5)
            func allNodes(_ n: SCNNode) -> [SCNNode] { [n] + n.childNodes.flatMap(allNodes) }
            check("scene nodes: nothing moves when not animated (Reduce Motion, pictures)", allNodes(still).allSatisfy { !$0.hasActions })
            let moving = SceneBuilder.partsNode(a, dark: true, animated: true)
            check("scene nodes: the three orbits turn when animated", allNodes(moving).filter(\.hasActions).count == 3)
            let electrons = parts.filter { $0.name?.hasPrefix("part:e") == true }.map { $0.simdConvertPosition(.zero, to: still) }
            check("scene nodes: the electrons start apart (they don't stack in a still frame)",
                  electrons.count == 3 && simd_distance(electrons[0], electrons[1]) > 1 && simd_distance(electrons[1], electrons[2]) > 1 && simd_distance(electrons[0], electrons[2]) > 1)
            let built = SceneBuilder.scene(a, dark: false, animated: false)
            check("scene nodes: the camera and lights sit outside the parts",
                  built.scene.rootNode.childNodes.filter { $0.light != nil }.count == 3 && built.camera.camera != nil
                    && SceneBuilder.partNodes(in: built.scene.rootNode).count == 5)
            let (lo, hi) = SceneBuilder.bounds(still)
            check("scene nodes: the framing box holds the whole orbit", hi.x >= 2.6 && lo.x <= -2.6)
        }
        if let f {
            let tree = SceneBuilder.partsNode(f, dark: false, animated: true)
            let arrows = SceneBuilder.partNodes(in: tree).filter { n in f.parts.contains { $0.kind == .arrow && "part:" + $0.id == n.name } }
            check("scene nodes: each arrow is 2 child nodes (shaft and head)", arrows.count == 4 && arrows.allSatisfy { $0.childNodes.count == 2 })
            check("scene nodes: arrows point where they say (weight down, push right)", {
                let w = tree.childNode(withName: "part:w", recursively: true), p = tree.childNode(withName: "part:p", recursively: true)
                let wTip = w?.childNodes.last.map { $0.simdConvertPosition(.zero, to: tree) } ?? .zero
                let pTip = p?.childNodes.last.map { $0.simdConvertPosition(.zero, to: tree) } ?? .zero
                return wTip.y < -1.5 && abs(wTip.x) < 0.01 && pTip.x > 1.5 && abs(pTip.y) < 0.01
            }())
            check("scene nodes: labels face the camera", SceneBuilder.partNodes(in: tree).filter { $0.constraints?.first is SCNBillboardConstraint }.count == 4)
        }
        let down = SceneBuilder.rotation(toward: [0, -1, 0]).act([0, 1, 0])
        check("scene nodes: a straight-down arrow turns cleanly (no NaN)", down.x.isFinite && abs(down.y + 1) < 0.001)
        if let one = SceneSpec.parse(many) {
            check("scene nodes: a trimmed scene builds 12 nodes", SceneBuilder.partNodes(in: SceneBuilder.partsNode(one, dark: false, animated: false)).count == 12)
        }
    }
}
