import AppKit
import EventKit

/// Puts an event on the calendar. Margin writes through macOS's Calendar database, so an event lands in your
/// Google calendar when your Google account is added in System Settings → Internet Accounts (Calendars on).
/// Without that, "Open in Google Calendar" fills in Google's own new-event page in your browser instead.
enum CalendarStore {
    private static let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var hasAccess: Bool { status == .fullAccess }
    /// macOS has already been asked and the answer was no.
    static var isDenied: Bool { status == .denied || status == .restricted }

    /// Asks macOS (once; it remembers the answer). The prompt only appears the first time.
    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    // MARK: Calendars

    struct Destination: Identifiable, Hashable {
        let id: String
        /// "Kien Do", "Work"…
        let name: String
        /// "Google", "iCloud", "On My Mac"…
        let account: String
        let isGoogle: Bool
        var label: String { account.isEmpty ? name : "\(name) · \(account)" }
    }

    static func destinations() -> [Destination] {
        guard hasAccess else { return [] }
        return store.calendars(for: .event).filter(\.allowsContentModifications).map(destination)
            .sorted { ($0.isGoogle ? 0 : 1, $0.account, $0.name) < ($1.isGoogle ? 0 : 1, $1.account, $1.name) }
    }

    private static func destination(_ c: EKCalendar) -> Destination {
        let account = c.source?.title ?? ""
        let google = account.localizedCaseInsensitiveContains("google") || account.localizedCaseInsensitiveContains("gmail")
        return Destination(id: c.calendarIdentifier, name: c.title, account: account, isGoogle: google)
    }

    /// Where an event goes unless you pick: the one you used last, else your main Google calendar, else the Mac's default.
    static func preferred() -> Destination? {
        let all = destinations()
        if let saved = UserDefaults.standard.string(forKey: "calendarID"), let hit = all.first(where: { $0.id == saved }) { return hit }
        if let google = all.first(where: { $0.isGoogle && $0.name.contains("@") }) ?? all.first(where: \.isGoogle) { return google }
        if let d = store.defaultCalendarForNewEvents, d.allowsContentModifications { return destination(d) }
        return all.first
    }

    static func remember(_ d: Destination) { UserDefaults.standard.set(d.id, forKey: "calendarID") }

    // MARK: Add and undo

    enum AddError: LocalizedError {
        case noAccess, noCalendar, failed(String)
        var errorDescription: String? {
            switch self {
            case .noAccess: return "Margin doesn't have access to your calendars. Allow it in System Settings → Privacy & Security → Calendars."
            case .noCalendar: return "That calendar isn't available any more."
            case .failed(let m): return m
            }
        }
    }

    /// Adds the event and returns its identifier (for Undo).
    static func add(_ draft: CalendarIntent.Draft, to destination: Destination) throws -> String {
        guard hasAccess else { throw AddError.noAccess }
        guard let calendar = store.calendar(withIdentifier: destination.id) else { throw AddError.noCalendar }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.calendar = calendar
        event.notes = "Added by Margin"
        if draft.allDay {
            event.isAllDay = true
            event.startDate = Calendar.current.startOfDay(for: draft.start)
            event.endDate = event.startDate
        } else {
            event.startDate = draft.start
            event.endDate = draft.end
        }
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw AddError.failed(error.localizedDescription)
        }
        return event.eventIdentifier ?? ""
    }

    /// Takes back an event Margin just added.
    @discardableResult
    static func remove(_ identifier: String) -> Bool {
        guard hasAccess, let event = store.event(withIdentifier: identifier) else { return false }
        return (try? store.remove(event, span: .thisEvent, commit: true)) != nil
    }

    // MARK: Google Calendar on the web

    /// Google's "new event" page with everything filled in (you press Save there). Works with any Google account
    /// and needs no permission from macOS.
    static func googleURL(_ d: CalendarIntent.Draft, calendar: Calendar = .current) -> URL {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        var dates: String
        if d.allDay {
            f.dateFormat = "yyyyMMdd"
            let next = calendar.date(byAdding: .day, value: 1, to: d.start) ?? d.start
            dates = "\(f.string(from: d.start))/\(f.string(from: next))"
        } else {
            f.dateFormat = "yyyyMMdd'T'HHmmss"
            dates = "\(f.string(from: d.start))/\(f.string(from: d.end))"
        }
        var c = URLComponents(string: "https://calendar.google.com/calendar/render")!
        c.queryItems = [
            URLQueryItem(name: "action", value: "TEMPLATE"),
            URLQueryItem(name: "text", value: d.title),
            URLQueryItem(name: "dates", value: dates),
            URLQueryItem(name: "ctz", value: calendar.timeZone.identifier),
            URLQueryItem(name: "details", value: "Added by Margin"),
        ]
        return c.url!
    }
}
