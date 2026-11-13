import AppKit
import SwiftUI

// MARK: - The orb

/// Margin's spark in a glowing orb: it breathes, a ring turns around it and a bright point drifts along the ring.
/// It's the Assistant's button in the Library and in Settings. Still (and calm) with Reduce Motion.
struct AssistantOrb: View {
    var size: CGFloat = 30
    /// Brighter while the pointer is over it or its card is open.
    var lit = false
    /// Faster while the Assistant is working.
    var busy = false

    private var still: Bool { Motion.still || Motion.reduceMotion }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: still)) { context in
            let t = still ? 0.0 : context.date.timeIntervalSinceReferenceDate
            let speed = busy ? 2.2 : 1.0
            let pulse = still ? 0.6 : 0.5 + 0.5 * sin(t * speed * 2 * .pi / 3.2)
            let spin = still ? 0.0 : (t * speed * 360 / 9).truncatingRemainder(dividingBy: 360)
            orb(pulse: pulse, spin: spin)
        }
        .frame(width: size, height: size)
        .animation(Motion.still ? nil : .easeOut(duration: 0.25), value: lit)
        .accessibilityHidden(true)
    }

    private func orb(pulse: Double, spin: Double) -> some View {
        let accent = Theme.accent.color
        let glow = (lit ? 0.75 : 0.5) * (0.65 + 0.35 * pulse)
        return ZStack {
            // The glow, wider than the orb.
            Circle()
                .fill(RadialGradient(colors: [accent.opacity(glow), accent.opacity(0)], center: .center,
                                     startRadius: size * 0.25, endRadius: size * (0.78 + 0.1 * pulse)))
                .frame(width: size * 1.7, height: size * 1.7)
            // The disc.
            Circle().fill(Theme.canvas.color)
                .overlay(Circle().fill(accent.opacity(0.10 + 0.08 * pulse)))
            // The ring, brightest at one end, turning.
            Circle()
                .strokeBorder(AngularGradient(colors: [accent, accent.opacity(0.08), accent.opacity(0.08), accent],
                                              center: .center), lineWidth: max(1.2, size * 0.055))
                .rotationEffect(.degrees(spin))
            // A bright point on the ring.
            Circle().fill(accent).frame(width: size * 0.1, height: size * 0.1)
                .offset(y: -size / 2 + size * 0.03)
                .rotationEffect(.degrees(-spin * 1.6))
            // The spark.
            SparkShape()
                .stroke(accent, style: StrokeStyle(lineWidth: ClaudeMark.lineWidth(radius: size * 0.27), lineCap: .round))
                .frame(width: size * 0.54, height: size * 0.54)
                .scaleEffect(0.94 + 0.12 * pulse)
                .rotationEffect(.degrees(spin * 0.35))
                .shadow(color: accent.opacity(0.7), radius: size * 0.12)
        }
    }
}

/// The Assistant's row under Sectors in the Library, and at the foot of the settings list.
struct AssistantOrbRow: View {
    var open = false
    var busy = false
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                AssistantOrb(size: 26, lit: hover || open, busy: busy).frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Assistant").font(.geist(13, .semibold)).foregroundStyle(Theme.ink.color)
                    Text(busy ? "Working…" : "Ask for anything").font(.geist(11)).foregroundStyle(Theme.inkTertiary.color).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 12).padding(.trailing, 8).frame(height: 46)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .fill(open ? Theme.surfaceSelected.color : (hover ? Theme.surfaceSelected.color.opacity(0.55) : Color.clear)))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                .strokeBorder(Theme.ink.color.opacity(open || hover ? 0.32 : 0.16), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(Motion.still ? nil : .easeOut(duration: 0.15), value: hover)
        .help("Assistant: find, tidy, star, file, change settings or shortcuts")
        .accessibilityLabel("Assistant")
    }
}

// MARK: - Commands

/// Everything the Assistant can do for you, as things to pick. `fill` ones need your words, so they open the text box.
struct AssistantCommand: Identifiable {
    let title: String
    let symbol: String
    let prompt: String
    var fill = false
    var id: String { title }
}

struct AssistantCommandGroup: Identifiable {
    let name: String
    let commands: [AssistantCommand]
    var id: String { name }
}

enum AssistantCommands {
    static let groups: [AssistantCommandGroup] = [
        .init(name: "Find and ask", commands: [
            .init(title: "Find chats…", symbol: "magnifyingglass", prompt: "Find my chats about ", fill: true),
            .init(title: "Library stats", symbol: "chart.bar", prompt: "How many chats, notes and screenshots do I have, and how many did I save this month?"),
            .init(title: "About Margin", symbol: "info.circle", prompt: "What can Margin do, and what are its shortcuts?"),
        ]),
        .init(name: "Tidy up", commands: [
            .init(title: "Star this week's chats", symbol: "star", prompt: "Star my chats from this week"),
            .init(title: "Add to To review…", symbol: "bookmark", prompt: "Put my chats about  in To review", fill: true),
            .init(title: "File chats under…", symbol: "folder", prompt: "Move my chats from this week to ", fill: true),
            .init(title: "New sector…", symbol: "plus.rectangle", prompt: "Create a sector called ", fill: true),
            .init(title: "Clear out old chats", symbol: "trash", prompt: "Delete chats older than 30 days that aren't starred"),
        ]),
        .init(name: "Change Margin", commands: [
            .init(title: "Dark mode", symbol: "moon", prompt: "Switch Margin to dark mode"),
            .init(title: "Light mode", symbol: "sun.max", prompt: "Switch Margin to light mode"),
            .init(title: "Accent colour…", symbol: "paintpalette", prompt: "Make the accent colour ", fill: true),
            .init(title: "Change a shortcut…", symbol: "keyboard", prompt: "Change the shortcut for the Library to ", fill: true),
            .init(title: "Learn mode", symbol: "graduationcap", prompt: "Turn on Learn mode"),
            .init(title: "Local mode", symbol: "lock.laptopcomputer", prompt: "Turn on Local mode"),
            .init(title: "Stop saving screenshots", symbol: "camera.viewfinder", prompt: "Turn off saving screenshots"),
        ]),
    ]

    static var all: [AssistantCommand] { groups.flatMap(\.commands) }
}

/// The box of commands: they settle in one after another and a soft highlight follows the pointer.
struct AssistantCommandTray: View {
    let choose: (AssistantCommand) -> Void
    var maxHeight: CGFloat = 300
    @State private var shown = Motion.still
    @State private var hovered: String?
    private static let order = Dictionary(uniqueKeysWithValues: AssistantCommands.all.enumerated().map { ($1.id, $0) })

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(AssistantCommands.groups) { group in
                    Text(group.name).font(.geist(11, .semibold)).foregroundStyle(Theme.inkTertiary.color)
                        .padding(.horizontal, 10).padding(.top, group.id == AssistantCommands.groups.first?.id ? 4 : 10).padding(.bottom, 3)
                        .opacity(shown ? 1 : 0)
                    ForEach(group.commands) { command in
                        row(command, order: Self.order[command.id] ?? 0)
                    }
                }
            }
            .padding(5)
        }
        .frame(height: maxHeight) // fixed: the conversation above would otherwise squeeze it
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).fill(Theme.surfaceRaised.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous).strokeBorder(Theme.hairline.color, lineWidth: 1))
        .onAppear { shown = true }
    }

    private func row(_ command: AssistantCommand, order: Int) -> some View {
        let on = hovered == command.id
        return Button { choose(command) } label: {
            HStack(spacing: 10) {
                Image(systemName: command.symbol).font(.system(size: 12))
                    .foregroundStyle(on ? Theme.accentText.color : Theme.inkSecondary.color).frame(width: 18)
                Text(command.title).font(.geist(13, .medium)).foregroundStyle(Theme.ink.color)
                Spacer(minLength: 0)
                if command.fill { Image(systemName: "text.cursor").font(.system(size: 10)).foregroundStyle(Theme.inkTertiary.color).opacity(on ? 1 : 0) }
            }
            .padding(.horizontal, 10).frame(height: 32)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip, style: .continuous).fill(on ? Theme.surfaceSelected.color : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(Motion.still ? nil : Motion.animation(Motion.small)) { hovered = inside ? command.id : (hovered == command.id ? nil : hovered) }
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || Motion.reduceMotion ? 0 : -6)
        .animation(Motion.reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.82).delay(Double(min(order, 12)) * 0.03), value: shown)
    }
}

// MARK: - The Library's card

/// The Assistant floating beside the Library's sidebar, over whatever the Library shows.
struct AssistantCard: View {
    let close: () -> Void
    @ObservedObject private var chat = AssistantChat.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                AssistantOrb(size: 22, lit: true, busy: chat.busy).frame(width: 28, height: 28)
                Text("Assistant").font(.geist(14, .semibold)).foregroundStyle(Theme.ink.color)
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.inkSecondary.color)
                        .frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).help("Close (Esc)").accessibilityLabel("Close the Assistant")
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            LibraryAssistantView(chat: chat, compact: true)
        }
        .frame(width: 430, height: 560)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.control + 6, style: .continuous).fill(Theme.canvas.color))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.control + 6, style: .continuous).strokeBorder(Theme.hairline.color, lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 26, y: 10)
        .onExitCommand(perform: close)
    }
}

/// The orb row, watching the Assistant so the orb speeds up while it works.
struct AssistantOrbButton: View {
    var open = false
    let action: () -> Void
    @ObservedObject private var chat = AssistantChat.shared
    var body: some View { AssistantOrbRow(open: open, busy: chat.busy, action: action) }
}
