import SwiftUI
import AppKit

private let accent = Theme.accent.color
private let good = Theme.done.color

/// The event Margin understood from "add … to my calendar", shown for you to check and change before it's added.
/// Nothing touches your calendar until you press Add.
struct EventCard: View {
    let source: String
    @State private var draft: CalendarIntent.Draft
    @State private var destinations: [CalendarStore.Destination] = []
    @State private var destination: CalendarStore.Destination?
    @State private var addedID: String?
    @State private var removed = false
    @State private var message: String?
    @State private var working = false

    init(source: String) {
        self.source = source
        _draft = State(initialValue: Self.decode(source) ?? CalendarIntent.Draft(title: "New event", start: Date(), end: Date().addingTimeInterval(3600)))
    }

    static func encode(_ d: CalendarIntent.Draft) -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return (try? String(decoding: e.encode(d), as: UTF8.self)) ?? "{}"
    }

    static func decode(_ s: String) -> CalendarIntent.Draft? {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(CalendarIntent.Draft.self, from: Data(s.utf8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if addedID != nil && !removed { Glyph(kind: .check, size: 12, color: good) }
                Text(addedID == nil || removed ? "Add to calendar" : "Added to calendar")
                    .mLabelStyle()
                    .foregroundStyle(addedID != nil && !removed ? good : Theme.inkSecondary.color)
                Spacer()
            }
            if addedID != nil && !removed {
                added
            } else {
                editor
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).fill(Theme.surface.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.container, style: .continuous).strokeBorder(Theme.hairlineStrong.color, lineWidth: 1))
        .onAppear(perform: loadDestinations)
    }

    // MARK: Editing

    private var editor: some View {
        VStack(alignment: .leading, spacing: 9) {
            TextField("Title", text: $draft.title)
                .textFieldStyle(.plain).font(.geist(12, .semibold))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(Theme.surfaceRaised.color))
            HStack(spacing: 8) {
                DatePicker("", selection: dayBinding, displayedComponents: .date).labelsHidden()
                if !draft.allDay {
                    DatePicker("", selection: $draft.start, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("to").font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
                    DatePicker("", selection: $draft.end, displayedComponents: .hourAndMinute).labelsHidden()
                }
                Spacer(minLength: 0)
            }
            Text(draft.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year()))
                .font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            HStack(spacing: 10) {
                Toggle("All day", isOn: $draft.allDay.animation()).toggleStyle(.checkbox).font(.geist(11.5))
                if draft.guessedMeridiem && !draft.allDay {
                    Button(isMorning ? "AM → PM" : "PM → AM") { flipHalfDay() }
                        .buttonStyle(.plain).font(.geist(12, .medium)).foregroundStyle(Theme.accentText.color)
                        .help("No am/pm was said, so Margin guessed. Tap to switch.")
                }
            }
            if let note = guessNote {
                Text(note).font(.geist(11.5)).foregroundStyle(Theme.alert.color)
            }
            destinationRow
            if let message { Text(message).font(.geist(11.5)).foregroundStyle(Theme.alert.color).fixedSize(horizontal: false, vertical: true) }
            HStack(spacing: 8) {
                Button { add() } label: { Label(working ? "Adding…" : "Add to Calendar", systemImage: "plus") }
                    .buttonStyle(CardButton(fill: accent, text: Theme.onAccent.color))
                    .disabled(working || draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { NSWorkspace.shared.open(CalendarStore.googleURL(draft)) } label: {
                    Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                }
                .buttonStyle(CardButton(fill: Theme.surfaceRaised.color, text: Theme.ink.color, border: true))
                .help("Opens Google's new-event page in your browser with everything filled in")
            }
        }
    }

    private var destinationRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar").font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            if let destination, destinations.count > 1 {
                Picker("", selection: Binding(get: { destination }, set: { self.destination = $0; CalendarStore.remember($0) })) {
                    ForEach(destinations) { Text($0.label).tag($0) }
                }
                .labelsHidden().fixedSize().font(.geist(11.5))
            } else if let destination {
                Text(destination.label).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            } else if CalendarStore.isDenied {
                Text("Calendar access is off for Margin.").font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
                Button("Open Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
                }.buttonStyle(.plain).font(.geist(12, .medium)).foregroundStyle(Theme.accentText.color)
            } else {
                Text(CalendarStore.hasAccess ? "No calendar to add to. Turn Calendars on for your account in System Settings."
                                              : "Your Mac will ask once to let Margin add events.")
                    .font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            }
        }
    }

    private var added: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(draft.title).font(.geist(12, .semibold))
            Text(summary).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color)
            if let destination { Text(destination.label).font(.geist(11.5)).foregroundStyle(Theme.inkSecondary.color) }
            HStack(spacing: 8) {
                Button { openCalendarApp() } label: { Label("Open Calendar", systemImage: "calendar") }
                    .buttonStyle(CardButton(fill: good.opacity(0.18), text: good))
                Button { undo() } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(CardButton(fill: Theme.surfaceRaised.color, text: Theme.inkSecondary.color))
            }
        }
    }

    // MARK: Pieces

    private var summary: String {
        let day = draft.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
        if draft.allDay { return day + " · all day" }
        let t = Date.FormatStyle(date: .omitted, time: .shortened)
        return day + " · " + draft.start.formatted(t) + " – " + draft.end.formatted(t)
    }

    private var guessNote: String? {
        var bits: [String] = []
        if draft.missingDate { bits.append("I didn't catch a date, so check it") }
        if draft.missingTime && !draft.allDay { bits.append("I didn't catch a time") }
        if draft.guessedMeridiem && !draft.allDay { bits.append("I guessed \(isMorning ? "AM" : "PM")") }
        return bits.isEmpty ? nil : bits.joined(separator: " · ")
    }

    private var isMorning: Bool { Calendar.current.component(.hour, from: draft.start) < 12 }

    /// Moves the date and keeps the times that were chosen.
    private var dayBinding: Binding<Date> {
        Binding(get: { draft.start }, set: { new in
            let cal = Calendar.current
            let s = cal.dateComponents([.hour, .minute], from: draft.start), e = cal.dateComponents([.hour, .minute], from: draft.end)
            let day = cal.startOfDay(for: new)
            draft.start = cal.date(bySettingHour: s.hour ?? 0, minute: s.minute ?? 0, second: 0, of: day) ?? new
            var end = cal.date(bySettingHour: e.hour ?? 0, minute: e.minute ?? 0, second: 0, of: day) ?? new
            if end <= draft.start { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
            draft.end = end
            draft.missingDate = false
        })
    }

    private func flipHalfDay() {
        let cal = Calendar.current
        let shift = isMorning ? 12 : -12
        draft.start = cal.date(byAdding: .hour, value: shift, to: draft.start) ?? draft.start
        draft.end = cal.date(byAdding: .hour, value: shift, to: draft.end) ?? draft.end
    }

    // MARK: Actions

    private func loadDestinations() {
        destinations = CalendarStore.destinations()
        destination = CalendarStore.preferred()
    }

    private func add() {
        message = nil
        guard CalendarStore.hasAccess else {
            if CalendarStore.isDenied { message = CalendarStore.AddError.noAccess.localizedDescription; return }
            working = true
            CalendarStore.requestAccess { granted in
                working = false
                loadDestinations()
                if granted { add() } else { message = CalendarStore.AddError.noAccess.localizedDescription }
            }
            return
        }
        guard let destination else { message = CalendarStore.AddError.noCalendar.localizedDescription; return }
        do {
            let id = try CalendarStore.add(draft, to: destination)
            withAnimation(.snappy(duration: 0.25)) { addedID = id; removed = false }
        } catch {
            message = error.localizedDescription
        }
    }

    private func undo() {
        if let id = addedID { CalendarStore.remove(id) }
        withAnimation(.snappy(duration: 0.25)) { removed = true; addedID = nil }
    }

    private func openCalendarApp() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app"))
    }
}

private struct CardButton: ButtonStyle {
    let fill: Color
    let text: Color
    var border = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.geist(12, .semibold))
            .foregroundStyle(text)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(fill).padding(border ? 1 : 0)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(border ? Theme.hairline.color : Color.clear)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
    }
}
