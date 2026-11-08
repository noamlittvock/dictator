import Foundation
import Observation

/// Where every captured prompt converges, whatever produced it: decides
/// save / ignore (policy, pause), drops duplicates across sources, redacts
/// secrets, and hands the result to history.
///
/// Duplicates are normal — a Codex prompt can arrive through its hook and
/// be typed into a watched window; a chat composer read and the keystroke
/// draft describe the same message. The rule: the most exact source wins.
/// Lower-fidelity captures (composer, keystrokes) wait `holdInterval` so an
/// exact connector record for the same text can supersede them.
@MainActor
@Observable
final class PromptRecorder {
    typealias Save = @MainActor (CapturedPrompt) async throws -> Void

    struct Recent: Equatable {
        var normalized: String
        var source: CaptureSource
        var toolID: String?
        var at: Date
    }

    /// Last capture per tool, for Settings ("last saved 2 min ago").
    private(set) var lastCaptureByTool: [String: Date] = [:]
    /// Where each tool was last captured ("iTerm → ssh box → Codex").
    private(set) var lastSurfaceByTool: [String: String] = [:]
    private(set) var lastError: String?

    @ObservationIgnored private let save: Save
    @ObservationIgnored private let notices: NoticedSurfaceStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private var pending: [UUID: (prompt: CapturedPrompt, task: Task<Void, Never>)] = [:]
    @ObservationIgnored private var recent: [Recent] = []
    /// Typing times of drafts typed on this Mac, for the exact capture of
    /// the same prompt that arrives through a connector.
    @ObservationIgnored private var typingLedger: [(normalized: String, seconds: Double, at: Date)] = []
    @ObservationIgnored private var storedKeys: [String] = []
    @ObservationIgnored private var storedKeySet = Set<String>()
    @ObservationIgnored private let keysURL: URL?

    var holdInterval: Duration = .seconds(4)
    static let duplicateWindow: TimeInterval = 120
    static let maxStoredKeys = 4_000

    init(
        settings: AppSettings = .shared,
        notices: NoticedSurfaceStore,
        keysURL: URL? = PromptRecorder.defaultKeysURL,
        save: @escaping Save
    ) {
        self.settings = settings
        self.notices = notices
        self.keysURL = keysURL
        self.save = save
        loadKeys()
        lastCaptureByTool = (UserDefaults.standard.dictionary(forKey: "promptLastCaptureByTool") as? [String: Date]) ?? [:]
        lastSurfaceByTool = (UserDefaults.standard.dictionary(forKey: "promptLastSurfaceByTool") as? [String: String]) ?? [:]
    }

    nonisolated static var defaultKeysURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dictator/captured-prompt-keys.json")
    }

    // MARK: - Entry point

    /// Fire-and-forget entry for keyboard / text-box captures.
    func submit(_ prompt: CapturedPrompt) {
        Task { _ = await self.ingest(prompt) }
    }

    /// Entry for connector records. Returns true once the prompt is dealt
    /// with — stored, a known duplicate, or deliberately not saved — so the
    /// caller may delete / acknowledge its record; false when saving failed
    /// and the record must be kept for a retry.
    @discardableResult
    func ingest(_ prompt: CapturedPrompt) async -> Bool {
        guard let text = ConnectorParsers.cleanPrompt(prompt.text) else { return true }
        var prompt = prompt
        prompt.text = text
        if prompt.source == .keystrokes,
           text.split(whereSeparator: \.isWhitespace).count < 2 { return true }
        if let key = prompt.dedupeKey, storedKeySet.contains(key) { return true }

        let decision = settings.captureDecision(for: prompt.context, modality: "typed", at: prompt.timestamp)
        guard decision.isSave else {
            noteIgnored(prompt, decision: decision)
            return true
        }

        if prompt.source.fidelity >= CaptureSource.transcript.fidelity {
            // Exact: supersedes a similar keyboard / text-box capture still
            // waiting. Two exact records are never merged by text — saying
            // "continue" twice is two prompts; only the record key dedupes.
            for (id, entry) in pending where Self.isSimilar(entry.prompt.text, text) {
                if prompt.typingSeconds == nil { prompt.typingSeconds = entry.prompt.typingSeconds }
                entry.task.cancel()
                pending.removeValue(forKey: id)
            }
            if prompt.typingSeconds == nil { prompt.typingSeconds = typingSeconds(for: text) }
            return await store(prompt)
        }
        let id = UUID()
        let hold = holdInterval
        let task = Task { [weak self] in
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled, let self else { return }
            self.pending.removeValue(forKey: id)
            if self.isSupersededByExact(prompt) { return }
            _ = await self.store(prompt)
        }
        pending[id] = (prompt, task)
        return true
    }

    /// Records how long a prompt took to type, whether or not the keyboard
    /// capture itself is saved (a connector may cover the tool).
    func noteTyping(text: String, seconds: Double, at date: Date) {
        let cutoff = Date().addingTimeInterval(-Self.duplicateWindow)
        typingLedger.removeAll { $0.at < cutoff }
        typingLedger.append((Self.normalize(text), seconds, date))
    }

    private func typingSeconds(for text: String) -> Double? {
        let cutoff = Date().addingTimeInterval(-Self.duplicateWindow)
        return typingLedger.last { $0.at >= cutoff && Self.isSimilar($0.normalized, text, firstIsNormalized: true) }?.seconds
    }

    // MARK: - Internals

    private func store(_ prompt: CapturedPrompt) async -> Bool {
        var prompt = prompt
        if settings.surfacePolicy.shouldScrubSecrets {
            prompt.text = SecretScrubber.scrub(prompt.text)
        }
        do {
            try await save(prompt)
            remember(prompt)
            if let toolID = prompt.context.toolID {
                lastCaptureByTool[toolID] = prompt.timestamp
                lastSurfaceByTool[toolID] = prompt.context.label()
                UserDefaults.standard.set(lastCaptureByTool, forKey: "promptLastCaptureByTool")
                UserDefaults.standard.set(lastSurfaceByTool, forKey: "promptLastSurfaceByTool")
            }
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            SyncDiagnostics.log("capture: save failed: \(error.localizedDescription)")
            return false
        }
    }

    private func remember(_ prompt: CapturedPrompt) {
        recent.append(Recent(normalized: Self.normalize(prompt.text), source: prompt.source, toolID: prompt.context.toolID, at: Date()))
        let cutoff = Date().addingTimeInterval(-Self.duplicateWindow)
        recent.removeAll { $0.at < cutoff }
        if let key = prompt.dedupeKey, storedKeySet.insert(key).inserted {
            storedKeys.append(key)
            if storedKeys.count > Self.maxStoredKeys {
                let overflow = storedKeys.count - Self.maxStoredKeys
                storedKeys.prefix(overflow).forEach { storedKeySet.remove($0) }
                storedKeys.removeFirst(overflow)
            }
            saveKeys()
        }
    }

    /// A keyboard / text-box capture that an exact source (hook, history
    /// file) already delivered.
    private func isSupersededByExact(_ prompt: CapturedPrompt) -> Bool {
        let cutoff = Date().addingTimeInterval(-Self.duplicateWindow)
        return recent.contains { item in
            item.at >= cutoff
                && item.source != prompt.source
                && item.source.fidelity > prompt.source.fidelity
                && Self.isSimilar(item.normalized, prompt.text, firstIsNormalized: true)
        }
    }

    private func noteIgnored(_ prompt: CapturedPrompt, decision: CaptureDecision) {
        guard decision.reason.hasPrefix("tool-off") || decision.reason.hasPrefix("tool-unset") else { return }
        // A tool the user deliberately switched off isn't news.
        guard decision.reason.hasPrefix("tool-unset") else { return }
        if !notices.isDismissed(kind: .toolOff, context: prompt.context) {
            notices.note(.toolOff, context: prompt.context)
        }
    }

    // MARK: - Similarity

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Same prompt, allowing for keystroke-reconstruction noise: equal after
    /// normalisation, one containing most of the other, ≥ 85 % shared words,
    /// or ≥ 80 % shared character trigrams (typos, a mangled edit).
    static func isSimilar(_ lhs: String, _ rhs: String, firstIsNormalized: Bool = false) -> Bool {
        let a = firstIsNormalized ? lhs : normalize(lhs)
        let b = normalize(rhs)
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let shorter = a.count < b.count ? a : b
        let longer = a.count < b.count ? b : a
        if longer.contains(shorter), Double(shorter.count) / Double(longer.count) >= 0.6 { return true }
        let wordsA = Set(a.split(separator: " "))
        let wordsB = Set(b.split(separator: " "))
        let union = wordsA.union(wordsB).count
        guard union > 0 else { return false }
        if Double(wordsA.intersection(wordsB).count) / Double(union) >= 0.85 { return true }
        let gramsA = trigrams(a), gramsB = trigrams(b)
        guard !gramsA.isEmpty, !gramsB.isEmpty else { return false }
        let dice = 2 * Double(gramsA.intersection(gramsB).count) / Double(gramsA.count + gramsB.count)
        return dice >= 0.8
    }

    private static func trigrams(_ text: String) -> Set<String> {
        let chars = Array(text.prefix(4_000))
        guard chars.count >= 3 else { return [] }
        var result = Set<String>()
        for index in 0...(chars.count - 3) {
            result.insert(String(chars[index..<(index + 3)]))
        }
        return result
    }

    private func loadKeys() {
        guard let keysURL, let data = try? Data(contentsOf: keysURL),
              let keys = try? JSONDecoder().decode([String].self, from: data) else { return }
        storedKeys = keys
        storedKeySet = Set(keys)
    }

    private func saveKeys() {
        guard let keysURL else { return }
        try? FileManager.default.createDirectory(at: keysURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(storedKeys) {
            try? data.write(to: keysURL, options: .atomic)
        }
    }

    func hasStored(key: String) -> Bool { storedKeySet.contains(key) }
}
