import Foundation
import SwiftUI

// MARK: - Plans and reports (what an agent shows you before and after)

/// A set of changes you can switch on or off as one: "Sort 112 screenshots into Screenshots/2026-10".
struct PlanGroup: Identifiable {
    let id = UUID()
    /// Stays the same when the plan is rebuilt ("sort:screenshot", "duplicates"), so your switches carry over.
    var key = ""
    var title: String
    var subtitle = ""
    var symbol: String
    var ops: [FileSafety.Op]
    /// A line per file, for "Show files".
    var files: [String] = []
    var enabled = true
    /// Moves things to the Trash.
    var removes = false
}

/// A choice that changes how the plan is carried out ("Name screenshots by what's in them").
struct PlanOption: Identifiable {
    let id: String
    var title: String
    var detail: String
    var on: Bool
}

/// A heads-up before an agent spends your Claude tokens: "this is a bigger job, about 14k tokens. Go ahead?"
struct TaskGate {
    var headline: String
    var detail: String
    /// Short, for the agent bar: "≈14k tokens · 312 items".
    var summary: String
}

struct TaskPlan {
    var headline: String
    var groups: [PlanGroup]
    var options: [PlanOption] = []
    /// Things left alone and why ("4 files you changed in the last 10 minutes").
    var notes: [String] = []
    /// What Allow would do, when the groups' own file operations don't say (an open-ended job: "3 steps · 12 files").
    var summaryOverride: String?

    var enabledOps: [FileSafety.Op] { groups.filter(\.enabled).flatMap(\.ops) }

    /// What pressing Allow would do, in a few words: "19 changes · 2 to the Trash".
    var summary: String {
        if let summaryOverride, groups.contains(where: \.enabled) {
            let on = groups.filter(\.enabled).count
            return on == groups.count ? summaryOverride : "\(on) of \(groups.count) steps"
        }
        let ops = enabledOps
        if ops.isEmpty { return groups.first(where: \.enabled)?.title ?? headline }
        let trashed = ops.filter { $0.kind == .trash }.count
        let base = "\(ops.count) change\(ops.count == 1 ? "" : "s")"
        return trashed > 0 ? base + " · \(trashed) to the Trash" : base
    }

    /// Allow can be pressed right away (something is switched on).
    var canApprove: Bool { groups.contains(where: \.enabled) }
    func option(_ id: String) -> Bool { options.first { $0.id == id }?.on ?? false }
}

struct TaskLink: Identifiable {
    let id = UUID()
    var title: String
    var url: URL
}

struct TaskReport {
    var headline: String
    var lines: [String] = []
    var links: [TaskLink] = []
}

// MARK: - A running task

/// One thing a background agent is doing. The sidebar shows a row for it; its card shows the plan and the report.
final class BackgroundTask: ObservableObject, Identifiable {
    enum Kind: String { case tidy, study, find, batch, custom

        var title: String {
            switch self {
            case .tidy: return "Tidy"
            case .study: return "Study"
            case .find: return "Find"
            case .batch: return "Batch"
            case .custom: return "Custom"
            }
        }
        var symbol: String {
            switch self {
            case .tidy: return "sparkles"
            case .study: return "graduationcap"
            case .find: return "magnifyingglass"
            case .batch: return "square.stack.3d.up"
            case .custom: return "wand.and.stars"
            }
        }
    }

    enum State: Equatable {
        case working
        case needsApproval
        case done
        case failed(String)
        case cancelled
    }

    let id = UUID()
    let kind: Kind
    @Published var title: String
    @Published var state: State = .working
    /// What it's doing right now ("Reading screenshots 40 of 150").
    @Published var detail = "Starting…"
    @Published var fraction: Double?
    /// Waiting for another agent to finish before it starts.
    @Published var queued = false
    @Published var plan: TaskPlan?
    /// A cost warning to say yes or no to before the agent starts spending tokens.
    @Published var gate: TaskGate?
    @Published var report: TaskReport?
    /// Claude tokens this task has used.
    @Published var tokens = 0
    @Published var canUndo = false
    @Published var undone = false
    /// Extra input the task needs (like which chapters), shown as part of the plan card.
    @Published var chooser: TaskChooser?

    // Hooks set by the agent that owns the task.
    var onApprove: ((BackgroundTask) -> Void)?
    var onCancel: (() -> Void)?
    var onUndo: ((BackgroundTask) -> Void)?
    var cancelRequested = false

    init(kind: Kind, title: String) {
        self.kind = kind
        self.title = title
    }

    /// What the bar shows under the agent's name while it waits for you.
    var approvalSummary: String {
        if let gate { return gate.summary }
        if let plan { return plan.summary }
        if let chooser {
            let on = chooser.items.filter(\.on).count
            return "Choose parts · \(on) of \(chooser.items.count) picked"
        }
        return "Needs your OK"
    }

    /// Allow can be pressed straight from the bar. Plans can; a choice (like which chapters to study, which costs Claude
    /// tokens) is made on the card first.
    var canQuickApprove: Bool { state == .needsApproval && ((plan?.canApprove ?? false) || gate != nil) && chooser == nil }

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: return true
        case .working, .needsApproval: return false
        }
    }

    func progress(_ text: String, _ fraction: Double? = nil) {
        DispatchQueue.main.async {
            self.detail = text
            self.fraction = fraction
        }
    }

    func finish(_ report: TaskReport, canUndo: Bool = false) {
        DispatchQueue.main.async {
            self.report = report
            self.canUndo = canUndo
            self.fraction = nil
            self.state = .done
            self.detail = report.headline
        }
    }

    func fail(_ message: String) {
        DispatchQueue.main.async {
            self.state = .failed(message)
            self.detail = message
            self.fraction = nil
        }
    }
}

/// A question an agent asks before it starts (Study: which chapters, and what to make of them).
struct TaskChooser {
    struct Choice: Identifiable {
        let id: String
        var title: String
        var detail = ""
        var on: Bool
    }
    var heading: String
    var items: [Choice]
    var optionsHeading: String
    var options: [Choice]
    /// "About 40k tokens", recomputed when a choice changes.
    var estimate: ((_ items: Set<String>, _ options: Set<String>) -> String)?
}
