import Foundation

/// Turns "add "study session" to my calendar at 8-9 on 8th of Jan 2027" into an event, on this Mac. Typed or
/// spoken, the words are read by rules here (no Claude call, so it costs nothing and works offline); the card
/// that follows shows exactly what was understood, with anything it had to guess marked, before anything is added.
enum CalendarIntent {
    struct Draft: Codable, Equatable {
        var title: String
        var start: Date
        var end: Date
        var allDay = false
        /// There was no am/pm, so it was guessed (8–9 became 8–9 AM).
        var guessedMeridiem = false
        /// No date was said (today or tomorrow was filled in).
        var missingDate = false
        /// No time was said (so it's a one-hour event at the next round hour, or all-day).
        var missingTime = false
    }

    // MARK: - Is this a calendar request?

    /// Words that put a request on a calendar. Spelling slips ("calender") count, since speech and typing make them.
    private static let calendarWord = rx(#"\b(?:calendar|calender|calandar|calendr|agenda|gcal|g-cal)\b"#)
    private static let addVerb = rx(#"\b(?:add|put|schedule|create|book|block|set up|setup|make|log|enter|insert|save|pencil)\b"#)
    private static let startsWithScheduling = rx(#"^\s*(?:hey,?\s+|please\s+|ok,?\s+|margin,?\s+|can you\s+|could you\s+)*(?:schedule|book|block off|block)\b"#)

    /// True for things like "add X to my calendar …" or "schedule a meeting tomorrow at 3". A plain question that
    /// merely mentions a calendar or a schedule isn't one.
    static func looksLikeRequest(_ text: String, now: Date = Date()) -> Bool {
        let lower = text.lowercased()
        if matches(calendarWord, lower), matches(addVerb, lower) { return true }
        if matches(startsWithScheduling, lower) {
            let parts = extract(lower, now: now, calendar: .current)
            return parts.date != nil || parts.time != nil
        }
        return false
    }

    // MARK: - Parse

    /// The event this asks for, or nil if it isn't a calendar request.
    static func parse(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Draft? {
        guard looksLikeRequest(text, now: now) else { return nil }

        // 1. A quoted title is the title, whatever else is in the sentence.
        var rest = text
        var quoted: String?
        if let m = firstMatch(rx(#"["“”«](.+?)["“”»]"#), in: rest) {
            quoted = m.group(1)
            rest = rest.replacingCharacters(in: m.range, with: " ")
        }

        // 2. The date and the time, taken out of what's left.
        let found = extract(rest, now: now, calendar: calendar)
        let title = clean(quoted ?? found.rest)

        var draft = build(found, now: now, calendar: calendar)
        draft.title = title.isEmpty ? "New event" : title
        return draft
    }

    struct Extracted {
        var date: Date?
        var time: TimeParts?
        var durationMinutes: Int?
        var hint: PartOfDay?
        /// What's left once the date and time words are removed.
        var rest: String
    }

    enum PartOfDay { case morning, afternoon, evening }

    struct TimeParts {
        var startHour: Int, startMinute: Int
        var endHour: Int?, endMinute: Int
        var guessed: Bool
        var allDay = false
    }

    static func extract(_ text: String, now: Date, calendar: Calendar) -> Extracted {
        var rest = text
        var out = Extracted(rest: text)
        let lower = { rest.lowercased() }

        // Date
        if let (date, range) = findDate(lower(), now: now, calendar: calendar) {
            out.date = date
            rest = (rest as NSString).replacingCharacters(in: range, with: " ")
        }
        // Part of day ("tonight", "morning"...). Kept as a hint for am/pm.
        if let m = firstMatch(rx(#"\b(tonight|this evening|in the evening|evening|this afternoon|in the afternoon|afternoon|in the morning|this morning|morning)\b"#), in: lower()) {
            let w = m.group(1)
            out.hint = w.contains("morning") ? .morning : (w.contains("afternoon") ? .afternoon : .evening)
            if w == "tonight", out.date == nil { out.date = calendar.startOfDay(for: now) }
            rest = (rest as NSString).replacingCharacters(in: m.range, with: " ")
        }
        // Duration
        if let m = firstMatch(rx(#"\bfor\s+(an?|\d+(?:\.\d+)?)\s*(hours?|hrs?|h|minutes?|mins?|m)\b"#), in: lower()) {
            let n = m.group(1) == "a" || m.group(1) == "an" ? 1.0 : Double(m.group(1)) ?? 1
            out.durationMinutes = Int(m.group(2).hasPrefix("h") ? n * 60 : n)
            rest = (rest as NSString).replacingCharacters(in: m.range, with: " ")
        }
        // Time
        if let (time, range) = findTime(lower(), hint: out.hint) {
            out.time = time
            rest = (rest as NSString).replacingCharacters(in: range, with: " ")
        }
        out.rest = rest
        return out
    }

    // MARK: Dates

    private static let months = ["jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
                                 "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8, "sep": 9, "sept": 9,
                                 "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11, "dec": 12, "december": 12]
    private static let monthNames = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    private static let weekdays = ["sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3, "wednesday": 4,
                                   "wed": 4, "thursday": 5, "thu": 5, "thur": 5, "thurs": 5, "friday": 6, "fri": 6, "saturday": 7, "sat": 7]

    private static func findDate(_ text: String, now: Date, calendar: Calendar) -> (Date, NSRange)? {
        let today = calendar.startOfDay(for: now)
        func day(_ d: Int, _ month: Int, _ year: Int?) -> Date? {
            var c = DateComponents()
            c.month = month; c.day = d
            if let year { c.year = year; return calendar.date(from: c) }
            // No year said: the next time that date comes round (today counts).
            c.year = calendar.component(.year, from: today)
            guard let this = calendar.date(from: c) else { return nil }
            return this >= today ? this : calendar.date(byAdding: .year, value: 1, to: this)
        }
        func fullYear(_ s: String) -> Int? {
            guard let n = Int(s) else { return nil }
            return n < 100 ? 2000 + n : n
        }

        // 8th of Jan 2027 / 8 January / 8th jan, 2027
        if let m = firstMatch(rx(#"\b(\d{1,2})(?:st|nd|rd|th)?\s+(?:of\s+)?(\#(monthNames))\.?(?:,?\s*(\d{4}))?\b"#), in: text),
           let d = Int(m.group(1)), (1...31).contains(d), let mo = months[String(m.group(2).prefix(m.group(2) == "sept" ? 4 : 3))] ?? months[m.group(2)],
           let date = day(d, mo, fullYear(m.group(3))) { return (date, m.range) }
        // Jan 8, 2027 / January 8th / the 8th of? (month first)
        if let m = firstMatch(rx(#"\b(\#(monthNames))\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?\b"#), in: text),
           let d = Int(m.group(2)), (1...31).contains(d), let mo = months[String(m.group(1).prefix(m.group(1) == "sept" ? 4 : 3))] ?? months[m.group(1)],
           let date = day(d, mo, fullYear(m.group(3))) { return (date, m.range) }
        // 2027-01-08
        if let m = firstMatch(rx(#"\b(\d{4})-(\d{1,2})-(\d{1,2})\b"#), in: text),
           let y = Int(m.group(1)), let mo = Int(m.group(2)), let d = Int(m.group(3)), let date = day(d, mo, y) { return (date, m.range) }
        // 8/1/2027 or 1/8: month first in the US, day first elsewhere
        if let m = firstMatch(rx(#"\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b"#), in: text), let a = Int(m.group(1)), let b = Int(m.group(2)) {
            let monthFirst = (DateFormatter.dateFormat(fromTemplate: "yMd", options: 0, locale: calendar.locale ?? .current) ?? "M").hasPrefix("M")
            let (mo, d) = monthFirst ? (a, b) : (b, a)
            if (1...12).contains(mo), (1...31).contains(d), let date = day(d, mo, fullYear(m.group(3))) { return (date, m.range) }
        }
        // Words
        if let m = firstMatch(rx(#"\b(day after tomorrow|tomorrow|today)\b"#), in: text) {
            let w = m.group(1)
            let offset = w == "tomorrow" ? 1 : (w == "day after tomorrow" ? 2 : 0)
            return (calendar.date(byAdding: .day, value: offset, to: today)!, m.range)
        }
        if let m = firstMatch(rx(#"\bin\s+(\d{1,3}|a|an|one|two|three|four|five)\s+(day|days|week|weeks)\b"#), in: text) {
            let words = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5]
            let n = Int(m.group(1)) ?? words[m.group(1)] ?? 1
            return (calendar.date(byAdding: .day, value: m.group(2).hasPrefix("week") ? n * 7 : n, to: today)!, m.range)
        }
        if let m = firstMatch(rx(#"\b(?:(next|this|on|coming)\s+)?(monday|tuesday|wednesday|thursday|friday|saturday|sunday|mon|tues?|wed|thu(?:rs?)?|fri)\b"#), in: text),
           let target = weekdays[m.group(2)] {
            if m.group(1) == "next" {
                // "Next Friday" is the Friday of next week (the week after this one).
                let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
                let nextWeek = calendar.date(byAdding: .day, value: 7, to: thisWeek)!
                let offset = (target - calendar.firstWeekday + 7) % 7
                return (calendar.date(byAdding: .day, value: offset, to: nextWeek)!, m.range)
            }
            let current = calendar.component(.weekday, from: today)
            var ahead = (target - current + 7) % 7
            if ahead == 0 { ahead = 7 } // the same weekday as today means a week from now
            return (calendar.date(byAdding: .day, value: ahead, to: today)!, m.range)
        }
        if let m = firstMatch(rx(#"\bnext week\b"#), in: text) { return (calendar.date(byAdding: .day, value: 7, to: today)!, m.range) }
        return nil
    }

    // MARK: Times

    private static let clock = #"(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)?"#

    private static func meridiem(_ s: String) -> Bool? {
        guard !s.isEmpty else { return nil }
        return s.hasPrefix("p") // true = pm
    }

    private static func findTime(_ text: String, hint: PartOfDay?) -> (TimeParts, NSRange)? {
        if let m = firstMatch(rx(#"\bnoon\b"#), in: text) { return (TimeParts(startHour: 12, startMinute: 0, endHour: nil, endMinute: 0, guessed: false), m.range) }
        if let m = firstMatch(rx(#"\bmidnight\b"#), in: text) { return (TimeParts(startHour: 0, startMinute: 0, endHour: nil, endMinute: 0, guessed: false), m.range) }
        if let m = firstMatch(rx(#"\ball[- ]day\b"#), in: text) {
            return (TimeParts(startHour: 0, startMinute: 0, endHour: nil, endMinute: 0, guessed: false, allDay: true), m.range)
        }

        // A range: 8-9, 8 to 9pm, from 8:30am until 10, between 2 and 4
        if let m = firstMatch(rx(#"(?:\b(?:from|at|between)\s+|@\s*)?\b"# + clock + #"\s*(?:-|–|—|to|until|till|through|and)\s*"# + clock + #"(?!\d)"#), in: text),
           let h1 = Int(m.group(1)), let h2 = Int(m.group(4)), h1 <= 24, h2 <= 24 {
            let m1 = Int(m.group(2)) ?? 0, m2 = Int(m.group(5)) ?? 0
            let (s, e, guessed) = resolveRange(h1, m1, meridiem(m.group(3)), h2, m2, meridiem(m.group(6)), hint)
            return (TimeParts(startHour: s.0, startMinute: s.1, endHour: e.0, endMinute: e.1, guessed: guessed), m.range)
        }
        // One time: at 8pm, 8:30 am, @ 7, 18:30
        if let m = firstMatch(rx(#"(?:\b(?:at|from|around|by|@)\s*)\b"# + clock + #"(?:\s*o'?clock)?"#), in: text)
            ?? firstMatch(rx(#"\b(\d{1,2})(?::(\d{2}))?\s*(a\.?m\.?|p\.?m\.?)(?!\w)"#), in: text)
            ?? firstMatch(rx(#"\b([01]?\d|2[0-3]):([0-5]\d)()\b"#), in: text),
           let h = Int(m.group(1)), h <= 24 {
            let min = Int(m.group(2)) ?? 0
            let mer = meridiem(m.group(3))
            let (s, _, guessed) = resolveRange(h, min, mer, nil, 0, nil, hint)
            return (TimeParts(startHour: s.0, startMinute: s.1, endHour: nil, endMinute: 0, guessed: guessed), m.range)
        }
        return nil
    }

    /// Fills in am/pm when it wasn't said. Returns (start, end, guessed).
    private static func resolveRange(_ h1: Int, _ m1: Int, _ mer1: Bool?, _ h2: Int?, _ m2: Int, _ mer2: Bool?,
                                     _ hint: PartOfDay?) -> ((Int, Int), (Int, Int), Bool) {
        func hour24(_ h: Int, pm: Bool) -> Int { h == 12 ? (pm ? 12 : 0) : (pm ? h % 12 + 12 : h % 12) }
        var guessed = false

        // 24-hour clock: 13+ can only be itself.
        if h1 >= 13 || (h2 ?? 0) >= 13 || (h1 == 0) {
            let s = (h1 % 24, m1)
            let e = h2.map { ($0 % 24, m2) } ?? ((h1 + 1) % 24, m1)
            return (s, e, false)
        }
        var pm1: Bool
        var pm2: Bool?
        if let mer1 {
            pm1 = mer1
            pm2 = mer2 ?? mer1
        } else if let mer2 {
            pm2 = mer2
            pm1 = mer2 // 8-9pm → both pm; fixed below if that puts the start after the end
        } else {
            guessed = true
            switch hint {
            case .morning: pm1 = false
            case .afternoon, .evening: pm1 = true
            case nil: pm1 = (1...6).contains(h1) || h1 == 12 // 1–6 mean the afternoon, 7–11 the morning
            }
            pm2 = pm1
        }
        var start = hour24(h1, pm: pm1)
        guard let h2 else { return ((start, m1), ((start + 1) % 24, m1), guessed) }
        var end = hour24(h2, pm: pm2 ?? pm1)
        if mer1 == nil, mer2 != nil, start * 60 + m1 >= end * 60 + m2 {
            pm1.toggle() // 11-1pm: the start is the morning
            start = hour24(h1, pm: pm1)
        }
        if end * 60 + m2 <= start * 60 + m1 {
            end = (end + 12) % 24 // 8-7: the end is in the evening (past midnight, the event runs into the next day)
        }
        return ((start, m1), (end, m2), guessed)
    }

    // MARK: Building the event

    private static func build(_ f: Extracted, now: Date, calendar: Calendar) -> Draft {
        var draft = Draft(title: "", start: now, end: now)
        let today = calendar.startOfDay(for: now)

        if let t = f.time, !t.allDay {
            var day = f.date ?? today
            draft.missingDate = f.date == nil
            func at(_ h: Int, _ m: Int) -> Date { calendar.date(bySettingHour: h, minute: m, second: 0, of: day) ?? day }
            var start = at(t.startHour, t.startMinute)
            if f.date == nil, start < now { // no date and the time has passed today: tomorrow
                day = calendar.date(byAdding: .day, value: 1, to: today)!
                start = at(t.startHour, t.startMinute)
            }
            var end: Date
            if let eh = t.endHour { end = at(eh, t.endMinute) } else { end = start.addingTimeInterval(TimeInterval((f.durationMinutes ?? 60) * 60)) }
            if end <= start { end = calendar.date(byAdding: .day, value: 1, to: end)! }
            if t.endHour != nil, let d = f.durationMinutes { end = start.addingTimeInterval(TimeInterval(d * 60)) }
            draft.start = start
            draft.end = end
            draft.guessedMeridiem = t.guessed
        } else if let date = f.date {
            if f.time?.allDay == true || f.durationMinutes == nil {
                draft.allDay = true
                draft.start = date
                draft.end = date
                draft.missingTime = true
            } else {
                let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: date) ?? date
                draft.start = start
                draft.end = start.addingTimeInterval(TimeInterval((f.durationMinutes ?? 60) * 60))
                draft.missingTime = true
            }
        } else {
            // Neither: the next round hour, for an hour, with the date and time both flagged.
            let next = calendar.nextDate(after: now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? now
            draft.start = next
            draft.end = next.addingTimeInterval(TimeInterval((f.durationMinutes ?? 60) * 60))
            draft.missingDate = true
            draft.missingTime = true
        }
        return draft
    }

    // MARK: Title

    /// What's left of the sentence after the request words are taken off it.
    private static func clean(_ raw: String) -> String {
        var s = " " + raw + " "
        let drops = [
            #"\b(?:hey|hi|ok|okay|please|margin|could you|can you|would you|i want to|i'd like to|i need to|i want you to)\b"#,
            #"\b(?:add|put|schedule|create|book|block off|block|set up|setup|make|log|enter|insert|save|pencil)\b"#,
            #"\b(?:to|on|in|into|onto|at|for|from|of|by)?\s*(?:my|the|our)?\s*(?:google\s+)?(?:calendar|calender|calandar|calendr|agenda|gcal|g-cal)\b"#,
        ]
        for d in drops { s = s.replacingOccurrences(of: d, with: " ", options: [.regularExpression, .caseInsensitive]) }
        // A dangling connector where the date used to be ("… on the", "… at "), behind any full stop.
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        s = s.replacingOccurrences(of: #"(?:\s+(?:on|at|for|from|to|in|by|the|a|an|and|-|–))+\s*$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"^\s*(?:(?:a|an|the|to|that|for)\s+)+"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        s = s.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters))
        guard let first = s.first else { return "" }
        return first.uppercased() + s.dropFirst()
    }

    // MARK: - Regex helpers

    private static func rx(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    struct Match {
        let range: NSRange
        let text: NSString
        let result: NSTextCheckingResult
        func group(_ i: Int) -> String {
            let r = result.range(at: i)
            return r.location == NSNotFound ? "" : text.substring(with: r)
        }
    }

    private static func firstMatch(_ regex: NSRegularExpression, in text: String) -> Match? {
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return Match(range: m.range, text: ns, result: m)
    }
}

private extension String {
    func replacingCharacters(in range: NSRange, with s: String) -> String {
        (self as NSString).replacingCharacters(in: range, with: s)
    }
}
