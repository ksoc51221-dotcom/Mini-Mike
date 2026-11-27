import Foundation

/// "Make this a note of a list of SUVAT equations": the detector, the title, create vs append, failure.
extension FeatureTests {
    final class FakeNoteStore: VoiceNote.Store {
        var sheets: [UUID: (title: String, markup: String)] = [:]
        var creates = 0, appends = 0
        func sheetID(titled title: String) -> UUID? { sheets.first { $0.value.title.lowercased() == title.lowercased() }?.key }
        func create(title: String, markup: String) -> Bool { creates += 1; sheets[UUID()] = (title, markup); return true }
        func append(to id: UUID, markup: String) -> Bool { appends += 1; sheets[id]?.markup += "\n" + markup; return true }
    }

    static func voiceNoteChecks(_ check: (String, Bool) -> Void) {
        func p(_ s: String) -> VoiceNote.Request? { VoiceNote.parse(s) }

        let a = p("Hey Merlin, make this a note of a list of SUVAT equations")
        check("voice note: 'make this a note of a list of SUVAT equations'", a?.title == "SUVAT Equations" && a?.topic == "a list of SUVAT equations")
        check("voice note: 'make a note of the SUVAT equations'", p("make a note of the SUVAT equations")?.title == "SUVAT Equations")
        check("voice note: 'put the quadratic formula in my notes'", p("put the quadratic formula in my notes")?.title == "Quadratic Formula")
        check("voice note: 'write a note on photosynthesis' needs two words, so 'on the process of photosynthesis' works",
              p("write a note on the process of photosynthesis")?.title == "Process of Photosynthesis")
        check("voice note: 'note down the first 10 elements'", p("note down the first 10 elements")?.title == "First 10 Elements")
        check("voice note: polite 'can you make a note about Newton's laws' works", p("can you make a note about Newton's three laws")?.title == "Newton's Three Laws")
        check("voice note: 'create a note about supply and demand, please'", p("create a note about supply and demand, please")?.title == "Supply and Demand")

        check("voice note: a plain question is not a note request", p("what is in my notes") == nil && p("can you explain notes to me") == nil)
        check("voice note: 'open my notes' is a note command, not mine", p("open my notes") == nil)
        check("voice note: 'new note called physics' stays with NoteCommand", p("make a new note called physics terms") == nil)
        check("voice note: 'remind me to call mum' and 'play some jazz' are not notes",
              p("remind me to call mum at five") == nil && p("play something by Maroon 5") == nil)
        check("voice note: 'make a note of this' has nothing to write from", p("make a note of this") == nil)
        check("voice note: 'make a note to buy milk' is not a generated note", p("make a note to buy milk tomorrow") == nil)
        check("voice note: a long ordinary chat request is not a note",
              p("I was wondering whether you could explain how note taking works for physics students in detail please") == nil)
        check("voice note: 'show the SUVAT equations' is not a note", p("show the SUVAT equations on screen") == nil)

        check("voice note: title drops 'a list of' and 'the'", VoiceNote.title(from: "a list of the SUVAT equations") == "SUVAT Equations")
        check("voice note: title keeps at most 5 words and ends on a real word",
              (VoiceNote.title(from: "the causes of the first world war in europe and asia")?.split(separator: " ").count ?? 9) <= 5)
        check("voice note: title keeps own capitals (pH, SUVAT)", VoiceNote.title(from: "pH and acids")?.hasPrefix("pH and") == true)

        // Create vs append vs failure (fake store: never the real Library).
        let req = VoiceNote.Request(topic: "a list of SUVAT equations", title: "SUVAT Equations")
        let store = FakeNoteStore()
        let l1 = VoiceNote.finish(req, body: "- v = u + at\n- s = ut + ½at²", store: store)
        check("voice note: first save creates the sheet", l1 == "Saved to the note \"SUVAT Equations\"" && store.creates == 1 && store.sheets.count == 1)
        let l2 = VoiceNote.finish(VoiceNote.Request(topic: "x y", title: "suvat equations"), body: "- v² = u² + 2as", store: store)
        check("voice note: same title (any case) appends, creates no second sheet",
              l2 == "Added to the note \"suvat equations\"" && store.appends == 1 && store.sheets.count == 1)
        let s2 = FakeNoteStore()
        check("voice note: a failed call says so and creates nothing", VoiceNote.finish(req, body: nil, store: s2) == VoiceNote.failureLine && s2.creates == 0 && s2.sheets.isEmpty)
        check("voice note: an empty reply creates nothing", VoiceNote.finish(req, body: "   \n", store: s2) == VoiceNote.failureLine && s2.sheets.isEmpty)
        check("voice note: a reply in a code fence loses the fence", VoiceNote.stripFence("```markdown\n- a\n```") == "- a")
        check("voice note: the prompt names the topic and asks for the body only",
              VoiceNote.prompt(for: req).contains("a list of SUVAT equations") && VoiceNote.prompt(for: req).contains("body only"))

        // The async path with a fake model.
        final class Box: @unchecked Sendable { var line = "" }
        let box = Box(), s3 = FakeNoteStore(), sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.line = await VoiceNote.perform(req, generate: { _ in "- F = ma" }, store: s3)
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 10)
        check("voice note: perform with a fake model saves the note", box.line == "Saved to the note \"SUVAT Equations\"" && s3.sheets.count == 1)
        let box2 = Box(), s4 = FakeNoteStore(), sem2 = DispatchSemaphore(value: 0)
        Task.detached {
            box2.line = await VoiceNote.perform(req, generate: { _ in throw VoiceNote.Failure() }, store: s4)
            sem2.signal()
        }
        _ = sem2.wait(timeout: .now() + 10)
        check("voice note: perform with a throwing model creates nothing", box2.line == VoiceNote.failureLine && s4.sheets.isEmpty)
    }
}
