import Foundation

extension FeatureTests {
    /// The one star in the chat header: what it shows and what a click does.
    static func chatStarChecks(_ check: (String, Bool) -> Void) {
        let s = ChatStar.state
        let fresh = s(true, false, true, false)
        check("chat star: a new answer in an unstarred chat: empty, a click stars the chat and keeps the answer",
              fresh.shown && !fresh.filled && fresh.keeps && fresh.togglesChat)
        let done = s(true, true, true, true)
        check("chat star: starred and kept: full, a click only unstars", done.filled && !done.keeps && done.togglesChat)
        let later = s(true, true, true, false)
        check("chat star: a starred chat with a new answer: empty, a click keeps and does not unstar",
              !later.filled && later.keeps && !later.togglesChat)
        let noAnswer = s(true, false, false, false)
        check("chat star: no answer to keep: a click only stars the chat", noAnswer.shown && !noAnswer.keeps && noAnswer.togglesChat)
        let starredNoAnswer = s(true, true, false, false)
        check("chat star: starred with nothing to keep is full", starredNoAnswer.filled && starredNoAnswer.togglesChat)
        let offHidden = s(false, false, false, false)
        check("chat star: history off and nothing to keep: no star", !offHidden.shown)
        let offKeep = s(false, false, true, false)
        check("chat star: history off: the star keeps the answer only", offKeep.shown && offKeep.keeps && !offKeep.togglesChat && !offKeep.filled)
        let offKept = s(false, false, true, true)
        check("chat star: history off and kept: full, no action", offKept.filled && !offKept.keeps && !offKept.togglesChat)
        check("chat star: the help text names both jobs", fresh.help.contains("Star") && fresh.help.contains("keep"))
    }
}
