import Foundation

/// The Library assistant (Settings → Assistant): you type what you want ("delete everything from last week that isn't
/// starred", "turn off saving screenshots", "find my chats about supply and demand"), Haiku turns it into a short list of
/// actions, and Merlin carries them out on the real Library. Claude only ever sees your sentence, the library's counts and
/// the titles of the last results, never the contents of your chats, and deleting anything waits for your OK first.
/// Everything here is plain logic (no UI), so it's tested with a throwaway Library and Settings.
final class LibraryAssistant {
    // MARK: What the model sends back

    struct Filter: Codable, Equatable {
        /// "chat", "note", "screenshot" (default: chats).
        var kinds: [String]?
        var query: String?
        var sector: String?
        /// yyyy-MM-dd, inclusive. Chats go by when they were last used; notes and screenshots by when they were made.
        var from: String?
        var to: String?
        var starred: Bool?
        /// Numbers from the last results list (#1, #2…).
        var refs: [Int]?
        /// "last" = everything in the last results list; "bin" = what's in the Bin.
        var scope: String?
        var limit: Int?

        init(kinds: [String]? = nil, query: String? = nil, sector: String? = nil, from: String? = nil, to: String? = nil,
             starred: Bool? = nil, refs: [Int]? = nil, scope: String? = nil, limit: Int? = nil) {
            self.kinds = kinds; self.query = query; self.sector = sector; self.from = from; self.to = to
            self.starred = starred; self.refs = refs; self.scope = scope; self.limit = limit
        }

        private enum CodingKeys: String, CodingKey { case kinds, query, sector, from, to, starred, refs, scope, limit }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kinds = (try? c.decodeIfPresent([String].self, forKey: .kinds)) ?? (try? c.decodeIfPresent(String.self, forKey: .kinds)).flatMap { $0 }.map { [$0] }
            query = try? c.decodeIfPresent(String.self, forKey: .query)
            sector = try? c.decodeIfPresent(String.self, forKey: .sector)
            from = try? c.decodeIfPresent(String.self, forKey: .from)
            to = try? c.decodeIfPresent(String.self, forKey: .to)
            starred = try? c.decodeIfPresent(Bool.self, forKey: .starred)
            refs = (try? c.decodeIfPresent([Int].self, forKey: .refs)) ?? (try? c.decodeIfPresent(Int.self, forKey: .refs)).flatMap { $0 }.map { [$0] }
            scope = try? c.decodeIfPresent(String.self, forKey: .scope)
            limit = try? c.decodeIfPresent(Int.self, forKey: .limit)
        }
    }

    struct Action: Codable, Equatable {
        /// find, count, open, delete, star, unstar, move, rename, restore, empty_bin, delete_forever, create_sector, set_setting.
        var type: String
        var filter: Filter?
        /// The target sector (move) or the new sector's name (create_sector).
        var sector: String?
        /// The new title (rename).
        var title: String?
        /// set_setting: which setting and what to set it to.
        var key: String?
        var value: String?

        init(type: String, filter: Filter? = nil, sector: String? = nil, title: String? = nil, key: String? = nil, value: String? = nil) {
            self.type = type; self.filter = filter; self.sector = sector; self.title = title; self.key = key; self.value = value
        }

        private enum CodingKeys: String, CodingKey { case type, filter, sector, title, key, value }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decode(String.self, forKey: .type)
            filter = try? c.decodeIfPresent(Filter.self, forKey: .filter)
            sector = try? c.decodeIfPresent(String.self, forKey: .sector)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            key = try? c.decodeIfPresent(String.self, forKey: .key)
            // The model may send true, 30 or "on" for a value.
            if let s = try? c.decodeIfPresent(String.self, forKey: .value) { value = s }
            else if let b = try? c.decodeIfPresent(Bool.self, forKey: .value) { value = b ? "true" : "false" }
            else if let i = try? c.decodeIfPresent(Int.self, forKey: .value) { value = String(i) }
        }
    }

    struct Plan: Equatable {
        var say: String
        var actions: [Action]
    }

    // MARK: What the actions find and do

    /// One thing in the Library (or the Bin), as the assistant lists it.
    struct Hit: Identifiable, Equatable {
        var ref: ItemRef
        var id: ItemRef { ref }
        var title: String
        var sector: String
        var date: Date
        var starred = false
        var inBin = false
    }

    struct Step {
        var text: String
        var hits: [Hit] = []
        var failed = false
        /// Puts this step back the way it was (nil when it can't be, or didn't change anything).
        var undo: (() -> Void)?
    }

    enum Risk: Int, Comparable {
        case safe, confirm, permanent
        static func < (a: Risk, b: Risk) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: Settings the assistant may change

    struct SettingSpec {
        var key: String
        var about: String
        var read: (Settings) -> String
        var write: (Settings, String) -> Bool
        /// For settings that don't live in `Settings` (colour, shortcuts): checks a value without changing anything.
        var validate: ((String) -> Bool)?
    }

    private static func boolSpec(_ key: String, _ about: String, _ kp: ReferenceWritableKeyPath<Settings, Bool>) -> SettingSpec {
        SettingSpec(key: key, about: about, read: { $0[keyPath: kp] ? "on" : "off" }, write: { s, v in
            guard let b = parseBool(v) else { return false }
            s[keyPath: kp] = b
            return true
        })
    }

    static func parseBool(_ v: String) -> Bool? {
        switch v.lowercased().trimmingCharacters(in: .whitespaces) {
        case "true", "on", "yes", "1", "enable", "enabled": return true
        case "false", "off", "no", "0", "disable", "disabled": return false
        default: return nil
        }
    }

    /// "lime", "Violet", or a hue in degrees ("200") → an accent colour.
    static func parseAccent(_ v: String) -> AccentTheme? {
        let t = v.trimmingCharacters(in: .whitespaces).lowercased()
        if let preset = AccentTheme.presets.first(where: { $0.name.lowercased() == t }) { return preset.theme }
        if let deg = Double(t.replacingOccurrences(of: "°", with: "")), (0...360).contains(deg) { return AccentTheme(hue: deg / 360) }
        return nil
    }

    static func accentName(_ a: AccentTheme) -> String {
        if let p = AccentTheme.presets.first(where: { $0.theme == a }) { return p.name.lowercased() }
        return String(Int(((a.hue ?? 0) * 360).rounded()))
    }

    static let settingSpecs: [SettingSpec] = [
        SettingSpec(key: "appearanceMode", about: "light or dark look: system, light or dark",
                    read: { _ in ThemeStore.shared.mode.rawValue },
                    write: { _, v in
                        guard let m = AppearanceMode(rawValue: v.lowercased().trimmingCharacters(in: .whitespaces)) else { return false }
                        ThemeStore.shared.setMode(m); return true
                    },
                    validate: { AppearanceMode(rawValue: $0.lowercased().trimmingCharacters(in: .whitespaces)) != nil }),
        SettingSpec(key: "accentColor", about: "Merlin's accent colour: lime, mint, aqua, sky, blue, violet, pink, coral, amber, or a hue 0-360",
                    read: { _ in accentName(ThemeStore.shared.accent) },
                    write: { _, v in
                        guard let a = parseAccent(v) else { return false }
                        ThemeStore.shared.setAccent(a); return true
                    },
                    validate: { parseAccent($0) != nil }),
        SettingSpec(key: "doubleShiftScreenshot", about: "tap Shift twice to add a screenshot to the open chat",
                    read: { _ in KeybindStore.shared.current.doubleShift ? "on" : "off" },
                    write: { _, v in
                        guard let b = parseBool(v) else { return false }
                        KeybindStore.shared.update { $0.doubleShift = b }; return true
                    },
                    validate: { parseBool($0) != nil }),
        boolSpec("saveHistory", "keep chats in the Library", \.saveHistory),
        boolSpec("nameChatsOnClose", "name chats when you close them", \.nameChatsOnClose),
        boolSpec("mirrorNotes", "also write kept notes to Documents/\(Notebook.folder.lastPathComponent)", \.mirrorNotes),
        boolSpec("saveScreenshots", "save your screenshots to the Library automatically", \.saveScreenshots),
        boolSpec("libraryShowPreviews", "show a preview line under each row", \.libraryShowPreviews),
        boolSpec("learnMode", "Learn mode (highlights the key words in answers)", \.learnMode),
        // Kept under its old key: "on" saves the old big size (570 × 660); only its width carries over to new chats (the height
        // is always automatic). "off" clears the saved size. Reads "on" whenever a size is saved.
        SettingSpec(key: "largePopup", about: "open new chats wide (on = 570 points wide; off = the normal width). The height always grows with the answer",
                    read: { $0.chatSize != nil ? "on" : "off" },
                    write: { s, v in
                        guard let b = parseBool(v) else { return false }
                        s.chatSize = b ? Settings.largeChatSize : nil
                        return true
                    }),
        boolSpec("chatsStayOpen", "chats stay open when you click away", \.chatsStayOpen),
        boolSpec("webSearch", "let answers use web search", \.webSearch),
        boolSpec("localMode", "Local mode (quick questions stay on this Mac)", \.localMode),
        SettingSpec(key: "libraryRowDensity", about: "row size in lists: comfortable or compact",
                    read: { $0.libraryRowDensity.rawValue },
                    write: { s, v in
                        guard let d = LibraryRowDensity(rawValue: v.lowercased()) else { return false }
                        s.libraryRowDensity = d; return true
                    }),
        SettingSpec(key: "libraryDefaultView", about: "what the Library opens on: desk, all or last",
                    read: { $0.libraryDefaultView.rawValue },
                    write: { s, v in
                        guard let d = LibraryDefaultView(rawValue: v.lowercased()) else { return false }
                        s.libraryDefaultView = d; return true
                    }),
        SettingSpec(key: "binAutoEmptyDays", about: "days the Bin keeps deleted things before deleting them for good (0 = never)",
                    read: { String($0.binAutoEmptyDays) },
                    write: { s, v in
                        guard let n = Int(v.trimmingCharacters(in: .whitespaces)), (0...3650).contains(n) else { return false }
                        s.binAutoEmptyDays = n; return true
                    }),
        SettingSpec(key: "screenshotRetentionDays", about: "days screenshots are kept before being deleted (0 = keep them)",
                    read: { String($0.screenshotRetentionDays) },
                    write: { s, v in
                        guard let n = Int(v.trimmingCharacters(in: .whitespaces)), (0...3650).contains(n) else { return false }
                        s.screenshotRetentionDays = n; return true
                    }),
    ]

    /// Settings that, lowered, delete things on their own the next time the Library tidies up.
    static let deletingSettings: Set<String> = ["binAutoEmptyDays", "screenshotRetentionDays"]

    // MARK: State

    let library: Library
    let settings: Settings
    let sectors: SectorStore?
    var calendar = Calendar.current
    var now: () -> Date = { Date() }
    /// The last list the assistant showed ("those", "#2" refer to it).
    private(set) var last: [Hit] = []

    init(library: Library = .shared, settings: Settings = .shared, sectors: SectorStore? = .shared) {
        self.library = library; self.settings = settings; self.sectors = sectors
    }

    // MARK: Talking to the model

    static let systemPrompt = """
    You run Merlin's Library for the user: a Mac app that keeps their saved chats (with Claude), notes, screenshots and a Bin. \
    Turn each request into actions. Reply with ONE JSON object and nothing else (no markdown fence):
    {"say": "one or two plain sentences to the user", "actions": [ ... ]}
    Merlin carries the actions out and reports what happened itself, so "say" only answers a question, asks one, or says what you're about to do. \
    Never claim something is done. If the request is unclear, or only chat, answer in "say" with "actions": [].

    Actions (objects with a "type"):
    - find: show matching things. {"type":"find","filter":{...}}
    - count: how many match. {"type":"count","filter":{...}}
    - open: open one result in the Library. {"type":"open","filter":{"refs":[2]}}
    - delete: move to the Bin (starred chats are never deleted). {"type":"delete","filter":{...}}
    - star / unstar: chats only. {"type":"star","filter":{...}}
    - set_keybind: change a shortcut. {"type":"set_keybind","key":"<shortcut id>","value":"option+cmd+j"} (value "reset" restores the default). Chords need cmd, option or control.
    - move: file chats or screenshots under a sector. {"type":"move","filter":{...},"sector":"Math"}
    - rename: one chat or screenshot. {"type":"rename","filter":{"refs":[1]},"title":"New title"}
    - restore: put things back from the Bin. {"type":"restore","filter":{"scope":"bin", ...}}
    - delete_forever: delete Bin things for good. {"type":"delete_forever","filter":{"scope":"bin", ...}}
    - empty_bin: delete everything in the Bin for good. {"type":"empty_bin"}
    - create_sector: {"type":"create_sector","sector":"Chemistry"}
    - set_setting: {"type":"set_setting","key":"<one of the settings>","value":"on"}
    - Mac actions ("title" = the app, song or routine name as the user said it; "value" = seconds): dock_add, dock_remove, app_open, \
    app_quit, music_play, music_pause, music_next, music_previous, music_star, timer_start, reminder_start (title = what to remember), \
    timer_cancel, routine_run. Example: {"type":"dock_add","title":"Notion"}

    filter fields (all optional, combine freely): "kinds" (["chat"],["note"],["screenshot"], default chats), "query" (words to search for), \
    "sector", "from" and "to" (yyyy-MM-dd, inclusive; work them out from TODAY), "starred" (true/false), "refs" (numbers from the last results list), \
    "scope" ("last" = everything in the last results list: use it for "those", "them", "it"; "bin" = the Bin), "limit".
    Several actions run in order (find, then delete scope "last" works). Use only the setting keys listed. Never invent ids or titles.

    About Merlin, for questions about it (answer in "say", briefly): highlight text anywhere and press the chat shortcut to ask Claude about it; \
    hold Tab then press \\ and drag to snip part of the screen; the talk shortcut asks by voice; Learn mode highlights the key words in answers; \
    tap Shift twice to attach a screenshot to the open chat; chats save to the Library, where you can star \
    them (starred chats stay at the top and can't be deleted), file them under sectors, and search; deleted things wait in the Bin. \
    Settings (Library → settings) has General, Appearance (light/dark and accent colour), Assistant, Rules, Shortcuts, Usage, Storage, Sectors, Privacy.
    """

    /// The user message: today's date, what the Library holds, the settings, the last results, the recent talk, then the request.
    func userPrompt(_ request: String, history: [(role: String, text: String)]) -> String {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.calendar = calendar; df.timeZone = calendar.timeZone; df.dateFormat = "yyyy-MM-dd (EEEE)"
        var lines = ["TODAY: \(df.string(from: now()))"]
        let used = library.usedSectors.map { "\($0.name) \($0.chats)c/\($0.notes)n" }.joined(separator: ", ")
        lines.append("LIBRARY: \(library.chats.count) chats (\(library.chats.filter(\.starred).count) starred), \(library.notes.count) notes, "
                     + "\(library.screenshots.count) screenshots, \(library.binned.count) in the Bin. Sectors: \(used.isEmpty ? "none yet" : used).")
        lines.append("SHORTCUTS (ids): " + ShortcutCommand.all.map { "\($0.id)=\(KeybindStore.shared.current.chord($0).display) (\($0.title), \($0.scope.heading.lowercased()))" }.joined(separator: "; "))
        let rules = String(settings.libraryRules.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Prompts.maxPersonal))
        if !rules.isEmpty { lines.append("USER RULES (follow these; they never override the hard locks):\n\(rules)") }
        var locks = ["starred chats are never deleted"]
        if settings.lockRenameLockedTitles { locks.append("chats with a locked title are never renamed") }
        if settings.lockAskBeforeMoving { locks.append("moving chats between sectors always waits for the user's Apply") }
        lines.append("HARD LOCKS (the app enforces these): " + locks.joined(separator: "; ") + ".")
        lines.append("SETTINGS: " + Self.settingSpecs.map { "\($0.key)=\($0.read(settings)) (\($0.about))" }.joined(separator: "; "))
        if !last.isEmpty {
            let shown = last.prefix(12).enumerated().map { "#\($0.offset + 1) \($0.element.title.prefix(60)) [\($0.element.ref.kind.rawValue)]" }
            lines.append("LAST RESULTS (\(last.count)): " + shown.joined(separator: " | ") + (last.count > 12 ? " | …" : ""))
        }
        if !history.isEmpty {
            lines.append("RECENT:\n" + history.suffix(6).map { "\($0.role): \($0.text.prefix(200))" }.joined(separator: "\n"))
        }
        lines.append("REQUEST: \(request)")
        return lines.joined(separator: "\n")
    }

    /// The model's reply as a plan, or nil if there's no usable JSON in it.
    static func parse(_ reply: String) -> Plan? {
        guard let open = reply.firstIndex(of: "{"), let close = reply.lastIndex(of: "}"), open < close else { return nil }
        let json = String(reply[open...close])
        struct Raw: Decodable { var say: String?; var actions: [Action]? }
        guard let data = json.data(using: .utf8), let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return Plan(say: raw.say ?? "", actions: raw.actions ?? [])
    }

    /// For the two settings that delete on their own: what the new value deletes for good, said before the user agrees.
    func deletionWarning(key: String, value: String) -> String {
        guard Self.deletingSettings.contains(key), let days = Int(value.trimmingCharacters(in: .whitespaces)), days > 0 else { return "" }
        if key == "screenshotRetentionDays" {
            let n = library.retentionWouldDelete(screenshotDays: days)
            return n == 0 ? " No screenshot is that old yet; later ones are deleted for good, not moved to the Bin."
                          : " This deletes \(n) screenshot\(n == 1 ? "" : "s") for good, not to the Bin. Undo can't bring them back."
        }
        let n = library.retentionWouldDelete(binDays: days)
        return n == 0 ? "" : " This deletes \(n) thing\(n == 1 ? "" : "s") in the Bin for good. Undo can't bring them back."
    }

    /// Whether you named this chat or screenshot yourself (its title is locked).
    private func titleIsLocked(_ ref: ItemRef) -> Bool {
        switch ref.kind {
        case .chat: return library.chat(ref.id)?.titleLocked ?? false
        case .screenshot: return library.screenshot(ref.id)?.titleLocked ?? false
        case .note: return false
        }
    }

    // MARK: Risk

    /// The risk of a plan with your hard locks applied: moving chats needs an OK while that lock is on.
    func effectiveRisk(of plan: Plan) -> Risk {
        plan.actions.map { a in
            let base = Self.risk(of: a)
            return a.type == "move" && settings.lockAskBeforeMoving ? max(base, .confirm) : base
        }.max() ?? .safe
    }

    static func risk(of a: Action) -> Risk {
        switch a.type {
        case "delete": return .confirm
        case "empty_bin", "delete_forever": return .permanent
        case _ where ActionCommand.confirmTypes.contains(a.type): return .confirm
        case "set_setting": return deletingSettings.contains(a.key ?? "") ? .confirm : .safe
        default: return .safe
        }
    }

    static func risk(of plan: Plan) -> Risk { plan.actions.map(risk(of:)).max() ?? .safe }

    // MARK: Resolving a filter

    private func day(_ s: String?, end: Bool) -> Date? {
        guard let s, !s.isEmpty else { return nil }
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.calendar = calendar; df.timeZone = calendar.timeZone; df.dateFormat = "yyyy-MM-dd"
        guard let d = df.date(from: String(s.prefix(10))) else { return nil }
        let start = calendar.startOfDay(for: d)
        return end ? calendar.date(byAdding: .day, value: 1, to: start)?.addingTimeInterval(-1) : start
    }

    private func hit(_ c: ChatRecord) -> Hit { Hit(ref: ItemRef(kind: .chat, id: c.id), title: c.title, sector: c.sector, date: c.updated, starred: c.starred) }
    private func hit(_ n: Note) -> Hit { Hit(ref: ItemRef(kind: .note, id: n.id), title: n.question, sector: n.sector, date: n.created) }
    private func hit(_ s: ScreenshotRecord) -> Hit { Hit(ref: ItemRef(kind: .screenshot, id: s.id), title: s.title, sector: s.sector, date: s.created) }
    private func hit(_ b: BinItem) -> Hit {
        Hit(ref: ItemRef(kind: b.kind, id: b.id), title: b.title, sector: b.sector, date: b.deleted, starred: b.chat?.starred ?? false, inBin: true)
    }

    private func exists(_ h: Hit) -> Bool {
        if h.inBin { return library.binItem(h.ref.id) != nil }
        switch h.ref.kind {
        case .chat: return library.chat(h.ref.id) != nil
        case .note: return library.notes.contains { $0.id == h.ref.id }
        case .screenshot: return library.screenshot(h.ref.id) != nil
        }
    }

    /// Everything a filter means, newest first.
    func resolve(_ f: Filter?) -> [Hit] {
        let f = f ?? Filter()
        var out: [Hit]
        if f.scope == "last" || f.refs != nil {
            let live = last.filter(exists)
            if let refs = f.refs { out = refs.compactMap { $0 >= 1 && $0 <= live.count ? live[$0 - 1] : nil } } else { out = live }
        } else if f.scope == "bin" {
            let q = (f.query ?? "").trimmingCharacters(in: .whitespaces)
            out = library.search(bin: q).map(hit)
        } else {
            let kinds = Set((f.kinds ?? ["chat"]).map { $0.lowercased() })
            let q = f.query ?? "", sec = (f.sector?.isEmpty == false) ? Sector.normalize(f.sector!, known: library.allSectors) : nil
            out = []
            if kinds.contains("chat") || kinds.contains("chats") { out += library.search(chats: q, sector: sec).map(hit) }
            if kinds.contains("note") || kinds.contains("notes") { out += library.search(notes: q, sector: sec).map(hit) }
            if kinds.contains("screenshot") || kinds.contains("screenshots") { out += library.search(screenshots: q, sector: sec).map(hit) }
        }
        if f.scope == "bin", let sec = f.sector, !sec.isEmpty { out = out.filter { $0.sector.caseInsensitiveCompare(sec) == .orderedSame } }
        if let from = day(f.from, end: false) { out = out.filter { $0.date >= from } }
        if let to = day(f.to, end: true) { out = out.filter { $0.date <= to } }
        if let starred = f.starred { out = out.filter { $0.ref.kind == .chat && $0.starred == starred } }
        out.sort { $0.date > $1.date }
        if let limit = f.limit, limit > 0 { out = Array(out.prefix(limit)) }
        return out
    }

    // MARK: Doing it

    private func noun(_ hits: [Hit]) -> String {
        let kinds = Set(hits.map(\.ref.kind))
        let one = kinds.count == 1 ? kinds.first : nil
        let word: String
        switch one {
        case .chat?: word = "chat"
        case .note?: word = "note"
        case .screenshot?: word = "screenshot"
        default: word = "item"
        }
        return "\(hits.count) \(word)\(hits.count == 1 ? "" : "s")"
    }

    private func range(_ f: Filter?) -> String {
        guard let f, f.from != nil || f.to != nil else { return "" }
        if let a = f.from, let b = f.to { return a == b ? " from \(a)" : " from \(a) to \(b)" }
        if let a = f.from { return " since \(a)" }
        return " up to \(f.to ?? "")"
    }

    /// Runs the plan. With `apply` false it only works out and describes each step (nothing changes), so you can approve it first.
    /// `confirmed` is true only when you pressed Apply on the preview; an action behind a hard lock that asks first (moving chats)
    /// is refused without it, whatever the model asked for.
    func run(_ plan: Plan, apply: Bool, confirmed: Bool = false) -> [Step] {
        var steps: [Step] = []
        for a in plan.actions { steps.append(step(a, apply: apply, confirmed: confirmed)) }
        return steps
    }

    private func step(_ a: Action, apply: Bool, confirmed: Bool) -> Step {
        switch a.type {
        case "find", "count":
            let hits = resolve(a.filter)
            last = hits
            if a.type == "count" { return Step(text: "\(noun(hits))\(range(a.filter)) match.", hits: []) }
            return Step(text: hits.isEmpty ? "Nothing matches." : "\(noun(hits)) found.", hits: Array(hits.prefix(50)))

        case "open":
            let hits = resolve(a.filter)
            guard let h = hits.first else { return Step(text: "I couldn't tell which one to open.", failed: true) }
            if apply { LibraryAssistant.openHook?(h.ref) }
            return Step(text: "Opening “\(h.title.prefix(50))”.")

        case "delete":
            let hits = resolve(a.filter).filter { !$0.inBin }
            let protected = hits.filter(\.starred)
            let doomed = hits.filter { !$0.starred }
            guard !doomed.isEmpty else {
                return Step(text: protected.isEmpty ? "Nothing to delete." : "Those are all starred, so none can be deleted. Unstar them first.", failed: true)
            }
            let suffix = protected.isEmpty ? "" : " (\(protected.count) starred \(protected.count == 1 ? "stays" : "stay"))"
            guard apply else { return Step(text: "Move \(noun(doomed))\(range(a.filter)) to the Bin\(suffix).", hits: Array(doomed.prefix(8))) }
            var gone: [UUID] = []
            for h in doomed {
                switch h.ref.kind {
                case .chat: if library.delete(chat: h.ref.id) { gone.append(h.ref.id) }
                case .note: library.delete(note: h.ref.id); gone.append(h.ref.id)
                case .screenshot: library.delete(screenshot: h.ref.id); gone.append(h.ref.id)
                }
            }
            return Step(text: "Moved \(gone.count == doomed.count ? noun(doomed) : "\(gone.count) of \(doomed.count)") to the Bin\(suffix). You can put them back from the Bin.",
                        undo: { for id in gone { _ = self.library.restore(id) } })

        case "star", "unstar":
            let on = a.type == "star"
            let hits = resolve(a.filter).filter { $0.ref.kind == .chat && !$0.inBin && $0.starred != on }
            guard !hits.isEmpty else { return Step(text: on ? "Nothing to star." : "Nothing to unstar.") }
            guard apply else { return Step(text: "\(on ? "Star" : "Unstar") \(noun(hits)).", hits: Array(hits.prefix(8))) }
            for h in hits { library.setStarred(h.ref.id, on) }
            let ids = hits.map(\.ref.id)
            return Step(text: "\(on ? "Starred" : "Unstarred") \(noun(hits)).", undo: { for id in ids { self.library.setStarred(id, !on) } })

        case "set_keybind":
            guard let key = a.key, let command = ShortcutCommand.named(key) else { return Step(text: "Which shortcut? Options: \(ShortcutCommand.all.map(\.id).joined(separator: ", ")).", failed: true) }
            let store = KeybindStore.shared
            let old = store.current.chord(command)
            let value = (a.value ?? "").trimmingCharacters(in: .whitespaces)
            if value.lowercased() == "reset" || value.lowercased() == "default" {
                let def = command.defaultChord
                guard apply else { return Step(text: "Put “\(command.title)” back to \(def.display).") }
                store.reset(command)
                return Step(text: "“\(command.title)” is back to \(def.display).", undo: { store.update { $0.chords[command.id] = old } })
            }
            guard let chord = Chord.parse(value) else { return Step(text: "I couldn't read “\(value)” as keys. Try something like option+cmd+J.", failed: true) }
            // The Settings page saves a clashing chord and shows it in red. Here nobody would see that, so a clash is refused.
            if let why = Keybinds.problem(chord, for: command) { return Step(text: why, failed: true) }
            if let other = store.current.rivals(of: command, using: chord).first { return Step(text: "\(chord.display) is already used for \(other.title).", failed: true) }
            if let fixed = Keybinds.fixedUse(of: chord) { return Step(text: "\(chord.display) is used by \(fixed). Pick another.", failed: true) }
            if !apply { return Step(text: "Change “\(command.title)” from \(old.display) to \(chord.display).") }
            store.set(chord, for: command)
            return Step(text: "“\(command.title)” is now \(chord.display) (was \(old.display)).", undo: { store.update { $0.chords[command.id] = old } })

        case "move":
            guard let target = a.sector, !target.trimmingCharacters(in: .whitespaces).isEmpty else { return Step(text: "Which sector should they go in?", failed: true) }
            let name = Sector.normalize(target, known: library.allSectors)
            let hits = resolve(a.filter).filter { ($0.ref.kind == .chat || $0.ref.kind == .screenshot) && !$0.inBin && $0.sector != name }
            guard !hits.isEmpty else { return Step(text: "Nothing to move.") }
            if apply, settings.lockAskBeforeMoving, !confirmed {
                return Step(text: "Locked by your Rules: I must ask before moving chats between sectors. Nothing was moved.", failed: true)
            }
            guard apply else { return Step(text: "File \(noun(hits)) under \(name).", hits: Array(hits.prefix(8))) }
            let chatIDs = hits.filter { $0.ref.kind == .chat }.map(\.ref.id)
            let shots = hits.filter { $0.ref.kind == .screenshot }
            let prev = Dictionary(uniqueKeysWithValues: shots.map { ($0.ref.id, $0.sector) })
            let undo = chatIDs.isEmpty ? nil : library.move(ids: chatIDs, toSector: name)
            for h in shots { library.move(screenshot: h.ref.id, toSector: name) }
            return Step(text: "Filed \(noun(hits)) under \(name).", undo: {
                if let undo { self.library.undo(undo) }
                for (id, old) in prev { self.library.move(screenshot: id, toSector: old) }
            })

        case "rename":
            let hits = resolve(a.filter).filter { ($0.ref.kind == .chat || $0.ref.kind == .screenshot) && !$0.inBin }
            let title = (a.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard hits.count == 1, let h = hits.first, !title.isEmpty else {
                return Step(text: hits.count > 1 ? "That's \(hits.count) things; tell me which one to rename." : "Tell me which one to rename, and to what.", failed: true)
            }
            if settings.lockRenameLockedTitles, titleIsLocked(h.ref) {
                return Step(text: "Locked by your Rules: “\(h.title.prefix(40))” has a locked title (you named it), so I won't rename it.", failed: true)
            }
            guard apply else { return Step(text: "Rename “\(h.title.prefix(40))” to “\(title.prefix(60))”.") }
            if h.ref.kind == .chat { library.rename(h.ref.id, to: title) } else { library.rename(screenshot: h.ref.id, to: title) }
            let old = h.title
            return Step(text: "Renamed it to “\(title.prefix(60))”.", undo: {
                if h.ref.kind == .chat { self.library.rename(h.ref.id, to: old) } else { self.library.rename(screenshot: h.ref.id, to: old) }
            })

        case "restore":
            var f = a.filter ?? Filter(); f.scope = "bin"
            let hits = resolve(f)
            guard !hits.isEmpty else { return Step(text: "The Bin has nothing like that.") }
            guard apply else { return Step(text: "Put \(noun(hits)) back from the Bin.", hits: Array(hits.prefix(8))) }
            let back = hits.filter { library.restore($0.ref.id) }
            return Step(text: "Put \(noun(back)) back.")

        case "delete_forever":
            var f = a.filter ?? Filter(); f.scope = "bin"
            let hits = resolve(f)
            guard !hits.isEmpty else { return Step(text: "The Bin has nothing like that.") }
            guard apply else { return Step(text: "Delete \(noun(hits)) from the Bin for good. This can't be undone.", hits: Array(hits.prefix(8))) }
            for h in hits { library.deleteForever(h.ref.id) }
            return Step(text: "Deleted \(noun(hits)) for good.")

        case "empty_bin":
            let n = library.binned.count
            guard n > 0 else { return Step(text: "The Bin is already empty.") }
            guard apply else { return Step(text: "Empty the Bin: delete all \(n) item\(n == 1 ? "" : "s") for good. This can't be undone.") }
            _ = library.emptyBin()
            return Step(text: "Emptied the Bin (\(n) item\(n == 1 ? "" : "s") deleted for good).")

        case "create_sector":
            let name = (a.sector ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let store = sectors else { return Step(text: "What should the sector be called?", failed: true) }
            guard apply else { return Step(text: "Create the sector “\(name)”.") }
            guard store.create(name: name) != nil else { return Step(text: "“\(name)” already exists, or isn't a usable name.", failed: true) }
            return Step(text: "Created the sector “\(name)”.")

        case "set_setting":
            guard let key = a.key, let spec = Self.settingSpecs.first(where: { $0.key == key }), let value = a.value else {
                return Step(text: "I can't change that setting.", failed: true)
            }
            let old = spec.read(settings)
            guard apply else {
                // Checked on a scratch copy, so a bad value is caught before anything real changes.
                let probe = "merlin.assistant.probe"
                let scratch = UserDefaults(suiteName: probe) ?? .standard
                defer { scratch.removePersistentDomain(forName: probe) }
                let valid = spec.validate?(value) ?? spec.write(Settings(defaults: scratch), value)
                return valid ? Step(text: "Set “\(spec.about)” to \(value) (now \(old)).\(deletionWarning(key: key, value: value))") : Step(text: "“\(value)” isn't a valid value for “\(spec.about)”.", failed: true)
            }
            guard spec.write(settings, value) else { return Step(text: "“\(value)” isn't a valid value for “\(spec.about)”.", failed: true) }
            return Step(text: "Set “\(spec.about)” to \(spec.read(settings)) (was \(old)).", undo: { _ = spec.write(self.settings, old) })

        case _ where ActionCommand.types.contains(a.type):
            // The fixed actions (dock, apps, music, timers, routines): the same runner as voice and the Ask box.
            guard let runner = Self.actionHook else { return Step(text: "I can't do that here.", failed: true) }
            guard apply else { return Step(text: "Will do: \(a.type.replacingOccurrences(of: "_", with: " ")) \(a.title ?? "")") }
            let out = runner.run(a, confirmed: confirmed)
            return Step(text: out.line, failed: !out.ok)

        default:
            return Step(text: "I don't know how to “\(a.type)”.", failed: true)
        }
    }

    /// The fixed actions' runner (set by the app; tests leave it empty).
    nonisolated(unsafe) static var actionHook: ActionRunner?

    /// Opens a result in the Library window (set by the app; tests leave it empty).
    nonisolated(unsafe) static var openHook: ((ItemRef) -> Void)? = { ref in
        let lib = LibraryWindow.shared
        lib.show(mode: ref.kind == .note ? .notebook : (ref.kind == .screenshot ? .screenshots : .all))
        lib.debugState.selection = ref
    }
}
