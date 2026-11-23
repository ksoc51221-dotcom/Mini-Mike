import Foundation

// Commands that act and do not start a chat (R4): "open microeconomics note", "add this to my macro note", "make a new
// note called macro terms", "show my chats". Decided on this Mac by rules, for zero tokens. A wrong command is worse than
// a missed one (a miss just asks Claude, as before), so the rules are strict.

// MARK: - Reading the words

/// Turns words into a note command, or nil. A command needs one of the verbs at the very start and either a note word
/// ("note", "notes", "sheet") in the right place or a name that exactly matches a sheet (see `SheetNames`).
enum NoteCommand {
    /// "open", "show", "go to", "bring up" → open. ("show me …" is allowed: "me" is skipped.)
    static let openVerbs: [[String]] = [["go", "to"], ["bring", "up"], ["open"], ["show"]]
    /// "add / put / save / append (this) to …" → add.
    static let addVerbs: Set<String> = ["add", "put", "save", "append"]
    /// "make / create / start (a new) note …" and "new note …" → new.
    static let newVerbs: Set<String> = ["make", "create", "start"]
    /// The words that mark a note. ("terms" is not one: "make a table of terms" is a question.)
    static let noteWords: Set<String> = ["note", "notes"] // not "sheet": "show the balance sheet" is a question
    static let chatsTargets: [[String]] = [["chats"], ["chat", "list"], ["conversations"]]
    static let notesTargets: [[String]] = [["notes"], ["note"]]
    /// What "add … to" may carry: nothing, or the answer itself. ("add 5 and 7", "add lunch to …" are not commands.)
    static let addObjects: [[String]] = [["the", "last", "answer"], ["this", "answer"], ["that", "answer"], ["the", "answer"],
                                         ["this"], ["that"], ["it"]]
    static let intoWords: Set<String> = ["to", "into", "in", "onto"]
    static let calledWords: Set<String> = ["called", "named", "titled"]
    /// A sentence that opens like a question is never a command.
    static let questionWords: Set<String> = ["what", "why", "how", "is", "are", "can", "could", "does", "do", "did", "will",
                                             "would", "should", "who", "when", "where", "which", "was", "were"]
    /// Words a note name may not hold, unless the whole name exactly matches a sheet ("notes on elasticity", "a note
    /// about photosynthesis", "a note of this" are requests for Claude).
    static let nameStops: Set<String> = ["how", "what", "why", "when", "where", "which", "who", "about", "on", "for", "with",
                                         "this", "that", "these", "those", "it", "me", "you", "a", "an", "new", "if"]
    static let maxWords = 12
    static let maxNameWords = 6

    /// `text` should already have the wake-up words off (`CommandCenter.cleaned`). `sheets`: the names of the sheets.
    static func parse(_ text: String, sheets: [String]) -> CommandCenter.Route? {
        var words = text.split(whereSeparator: \.isWhitespace)
            .map { String($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        if words.first?.lowercased() == "please" { words.removeFirst() }
        if words.last?.lowercased() == "please" { words.removeLast() }
        guard !words.isEmpty, words.count <= maxWords else { return nil }
        let lower = words.map { $0.lowercased() }
        guard !questionWords.contains(lower[0]) else { return nil }

        // Open
        for verb in openVerbs where lower.starts(with: verb) {
            var rest = Array(words.dropFirst(verb.count))
            if rest.first?.lowercased() == "me" { rest.removeFirst() }
            rest = dropLeading(["my", "the", "all"], rest)
            let restLower = rest.map { $0.lowercased() }
            if chatsTargets.contains(restLower) { return .openChats }
            if notesTargets.contains(restLower) { return .openNotes }
            return target(rest, sheets: sheets).map { .openNote($0) }
        }

        // Add
        if addVerbs.contains(lower[0]) {
            var rest = Array(words.dropFirst())
            if let object = addObjects.first(where: { rest.map { $0.lowercased() }.starts(with: $0) }) {
                rest.removeFirst(object.count)
            }
            guard let into = rest.first?.lowercased(), intoWords.contains(into) else { return nil }
            rest.removeFirst()
            return target(dropLeading(["my", "the"], rest), sheets: sheets).map { .addToNote($0) }
        }

        // New
        if newVerbs.contains(lower[0]) || lower[0] == "new" {
            var rest = Array(words.dropFirst())
            if lower[0] != "new" {
                if rest.first?.lowercased() == "me" { rest.removeFirst() }
                rest = dropLeading(["a", "an"], rest)
                if rest.first?.lowercased() == "new" { rest.removeFirst() }
            }
            // "… note called NAME": the note word right after the verb (one note, so singular), then "called", "named" or
            // "titled". Without that word it is a request for Claude ("make a note of the deadline", "make note cards").
            guard let first = rest.first?.lowercased(), first == "note" || first == "sheet" else { return nil }
            rest.removeFirst()
            guard let c = rest.first?.lowercased(), calledWords.contains(c) else { return nil }
            rest.removeFirst()
            return validName(rest).map { .newNote($0) }
        }
        return nil
    }

    /// The note a phrase means: "NAME note", "note called NAME", or a name that exactly matches a sheet.
    private static func target(_ rest: [String], sheets: [String]) -> String? {
        guard !rest.isEmpty else { return nil }
        let lower = rest.map { $0.lowercased() }
        if rest.count >= 2, let last = lower.last, noteWords.contains(last), let name = validName(Array(rest.dropLast())) {
            return name
        }
        if rest.count >= 3, noteWords.contains(lower[0]), calledWords.contains(lower[1]), let name = validName(Array(rest.dropFirst(2))) {
            return name
        }
        let whole = rest.joined(separator: " ")
        if SheetNames.match(whole, in: sheets).match != nil { return whole }
        return nil
    }

    /// A name of 1…6 words with no question or linking words, and more than filler ("my notes" is not a name).
    private static func validName(_ words: [String]) -> String? {
        let words = dropLeading(["my", "the"], words)
        guard !words.isEmpty, words.count <= maxNameWords else { return nil }
        let lower = words.map { $0.lowercased() }
        guard !lower.contains(where: { nameStops.contains($0) || noteWords.contains($0) }) else { return nil }
        guard lower.contains(where: { !SheetNames.filler.contains($0) }) else { return nil }
        return words.joined(separator: " ")
    }

    private static func dropLeading(_ skip: Set<String>, _ words: [String]) -> [String] {
        Array(words.drop { skip.contains($0.lowercased()) })
    }
}

// MARK: - Carrying it out

/// Runs a note command and gives one line to show ("Opened Microeconomics terms"). Its actions are passed in, so the unit
/// run checks every line with fakes and no windows. Zero Claude calls.
final class CommandRunner {
    /// The app's runner (set at launch). A blank chat's typed text goes through it too.
    nonisolated(unsafe) static var shared: CommandRunner?

    let library: Library
    let openSheet: (UUID) -> Void
    /// "Add this to …": the newest finished answer goes into the sheet that name means.
    let appendAnswer: (String) -> SheetActions.AppendResult
    /// Shows the edge panel pinned on that list. False if it could not show (a snip or point to ask is under way).
    let showPanel: (EdgePanelModel.Section) -> Bool

    init(library: Library, openSheet: @escaping (UUID) -> Void, appendAnswer: @escaping (String) -> SheetActions.AppendResult,
         showPanel: @escaping (EdgePanelModel.Section) -> Bool) {
        self.library = library
        self.openSheet = openSheet
        self.appendAnswer = appendAnswer
        self.showPanel = showPanel
    }

    /// The real one: the Library window, the open chat's answer, the edge panel.
    static func live(dock: AgentDock) -> CommandRunner {
        CommandRunner(library: .shared,
                      openSheet: { LibraryWindow.shared.show(sheet: $0) },
                      appendAnswer: { [weak dock] name in dock?.appendFrontAnswer(toSheetNamed: name) ?? .nothingToSave },
                      showPanel: { section in
                          EdgePanelController.shared.show(section)
                          return EdgePanelController.shared.isVisible
                      })
    }

    /// The same for spoken and typed words: wake-up words off, then the router with the sheets' names. Nil unless it is
    /// one of the note commands (calendar, video and questions go on as before).
    static func commandRoute(_ text: String, sheets: [String]) -> CommandCenter.Route? {
        let route = CommandCenter.route(CommandCenter.cleaned(text), sheets: sheets)
        return route.isNoteCommand ? route : nil
    }

    func commandRoute(_ text: String) -> CommandCenter.Route? {
        Self.commandRoute(text, sheets: library.sheets.map(\.name))
    }

    /// Does it, and says what happened. Nil for a route that is not a note command.
    func run(_ route: CommandCenter.Route) -> String? {
        switch route {
        case .openNote(let name):
            let found = library.findSheet(name)
            guard let sheet = found.sheet else { return Self.noMatch(found.closest) }
            openSheet(sheet.id)
            return "Opened \(sheet.name)"
        case .addToNote(let name):
            switch appendAnswer(name) {
            case .saved(let stored): return "Added to \(stored)"
            case .noMatch(let closest): return Self.noMatch(closest)
            case .nothingToSave: return "There is no answer to add yet."
            }
        case .newNote(let name):
            let title = Self.titled(name)
            if let same = library.sheets.first(where: { SheetNames.normalize($0.name) == SheetNames.normalize(title) }) {
                openSheet(same.id)
                return "That note exists already. Opened it."
            }
            guard let sheet = library.createSheet(named: title) else { return "That note needs a name." }
            openSheet(sheet.id)
            return "Made the note \(sheet.name)"
        case .openChats:
            return showPanel(.chats) ? "Showing your chats" : Self.panelBusy
        case .openNotes:
            return showPanel(.notes) ? "Showing your notes" : Self.panelBusy
        case .calendar, .video, .ask:
            return nil
        }
    }

    static let panelBusy = "The panel can't show right now. Try again in a moment."

    /// Never a guess: the two closest names, or that there are no notes at all.
    static func noMatch(_ closest: [String]) -> String {
        closest.isEmpty ? "You have no notes yet." : "No note with that name. Closest: \(closest.joined(separator: ", "))."
    }

    /// "macro terms" → "Macro terms" (only the first letter; the rest stays as said).
    static func titled(_ name: String) -> String {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.prefix(1).uppercased() + n.dropFirst()
    }
}
