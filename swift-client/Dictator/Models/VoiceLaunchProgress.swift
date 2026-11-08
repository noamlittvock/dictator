import AppKit
import Foundation

/// What the notice after key release shows: the shortcut, then each step as
/// it runs. Pure state so the transitions can be tested.
struct VoiceLaunchProgress: Equatable {
    enum State: Equatable { case waiting, running, done, failed, cancelled }
    enum Event: Equatable {
        case stepStarted(Int)
        case stepDone(Int)
        case stepFailed(Int)
        /// A "Sending in N s" pause is running; N whole seconds left.
        case countdown(Int, Int)
        case stepCancelled(Int)
    }
    struct Row: Equatable {
        var text: String
        var state: State = .waiting
        /// "Sending in 3 s — Esc to cancel", while a pause runs.
        var note: String?
    }

    var commandName: String
    /// The sentence as said, coloured by role; nil when the shortcut's pattern isn't known here.
    var phrase: [PhraseSegment]?
    var rows: [Row]

    init(plan: VoiceLaunchPlan, pattern: String? = nil) {
        commandName = plan.commandName
        phrase = pattern.map { SpokenPhrase.segments(for: plan, pattern: $0) }.flatMap { $0.isEmpty ? nil : $0 }
        rows = plan.steps.map { step in
            // The pause shows what is about to go out, already filled in.
            Row(text: step.kind == .confirm && !(step.text ?? "").isEmpty ? step.text ?? "" : VoiceStepDescription.short(step))
        }
    }

    mutating func apply(_ event: Event) {
        switch event {
        case .stepStarted(let i): set(i, .running)
        case .stepDone(let i): set(i, .done)
        case .stepFailed(let i): set(i, .failed)
        case .stepCancelled(let i): set(i, .cancelled)
        case .countdown(let i, let left):
            set(i, .running)
            if rows.indices.contains(i) { rows[i].note = VoiceLaunchCountdown.label(left) }
        }
    }

    private mutating func set(_ index: Int, _ state: State) {
        guard rows.indices.contains(index) else { return }
        rows[index].state = state
        if state != .running { rows[index].note = nil }
    }

    var hasFailed: Bool { rows.contains { $0.state == .failed } }
    var hasCancelled: Bool { rows.contains { $0.state == .cancelled } }
    var isFinished: Bool { hasFailed || hasCancelled || rows.allSatisfy { $0.state == .done } }
}

/// App names for bundle ids, for messages and the app picker.
enum VoiceAppNames {
    static func name(for target: String) -> String? {
        guard !target.contains("://"), let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: target) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}
