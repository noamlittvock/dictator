import AppKit
import Foundation

/// Surfaces "recording checkpoints" left on disk as two user actions —
/// Transcribe or Discard — for the menu bar and the History settings tab.
/// Checkpoints and history are this Mac's own; the speech goes through the
/// injected transcriber, which uses the same speech sources as live
/// dictation, the main Mac's included. A recovered take never routes
/// through the Core's session broker (its original focus/target context is
/// gone anyway — the text goes to the clipboard, not a paste).
@MainActor
@Observable
final class RecoveryService {
    struct RecoverableTake: Identifiable, Equatable {
        var id: String { take.id }
        let take: CheckpointTake

        var removalDate: Date {
            take.metadata.startedAt.addingTimeInterval(Double(RecordingCheckpointStore.retentionDays) * 86_400)
        }

        var retentionNote: String {
            "Removed at startup after \(removalDate.formatted(date: .abbreviated, time: .shortened)), or sooner if recovery storage fills up."
        }
    }

    private let store: RecordingCheckpointStore
    private let transcribeAudio: (CapturedAudio) async throws -> TranscriptionResult
    /// (text, durationSeconds, inferenceMs, source) → persist to history.
    /// Throws so a caller that can't actually persist the entry (a
    /// remote-history outage) can tell `transcribe` that, so the checkpoint
    /// is kept instead of unconditionally deleted.
    private let saveEntry: (String, Double, Int?, String) async throws -> Void
    private let saveEntryWithStages: ((String, String, Double, Int?, String) async throws -> Void)?
    /// A `.recording` checkpoint touched more recently than this
    /// might still be mid-`finish()` on another queue — see `refresh()`.
    private static let recentRecordingGracePeriod: TimeInterval = 10
    private let now: () -> Date

    private(set) var takes: [RecoverableTake] = []
    /// Take ids currently in flight on this machine — excluded from `takes`
    /// so a recording still being captured never shows as "unrecovered"
    /// mid-session. Setting this re-runs `refresh()`.
    var activeTakeIds: Set<String> = [] {
        didSet { refresh() }
    }
    private(set) var busyTakeIds: Set<String> = []
    var lastNotice: String?
    private(set) var lastAlert: DictationAlert?

    /// `transcribe` defaults to wiring the real `TranscriptionService`
    /// against `settings`/`loadDictionary` at call time — overridden in
    /// tests with a fake so `RecoveryServiceTests` never touches the
    /// network.
    init(
        store: RecordingCheckpointStore = RecordingCheckpointStore(),
        settings: AppSettings = .shared,
        loadDictionary: @escaping () async -> [[String: String]] = { [] },
        transcribe: ((CapturedAudio) async throws -> TranscriptionResult)? = nil,
        saveEntry: @escaping (String, Double, Int?, String) async throws -> Void,
        saveEntryWithStages: ((String, String, Double, Int?, String) async throws -> Void)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        if let transcribe {
            self.transcribeAudio = transcribe
        } else {
            // Without an injected closure (the app always injects one that uses
            // every speech source): try each configured server in order.
            let service = TranscriptionService()
            self.transcribeAudio = { audio in
                let dictionary = await loadDictionary()
                var sources = settings.speechSources.filter { $0.serverURL != nil }
                if sources.isEmpty { sources = [.server(settings.serverURL)] }
                do {
                    return try await SpeechSourceChain.run(
                        sources: sources,
                        audioSeconds: audio.durationSeconds,
                        reach: { source, timeout in
                            if let url = source.serverURL { try await TranscriptionService.checkReachable(serverURL: url, timeout: timeout) }
                        },
                        attempt: { source, limit in
                            try await service.transcribe(
                                audio: audio, serverURL: source.serverURL ?? settings.serverURL, refineLevel: settings.refineLevel,
                                dictionary: dictionary, languages: settings.dictationLanguages, timeout: limit
                            )
                        }
                    ).value
                } catch let failed as SpeechSourceChain.Failure {
                    throw failed.error
                }
            }
        }
        self.saveEntry = saveEntry
        self.saveEntryWithStages = saveEntryWithStages
        self.now = now
    }

    /// A `.recording` checkpoint is hidden while its sidecar was
    /// touched within the last `recentRecordingGracePeriod` — a writer may
    /// still be mid-`finish()` on `AudioCaptureService`'s checkpoint queue,
    /// and the PCM `listTakes()` measured a duration from could be about to
    /// change. An older `.recording` checkpoint is a genuine crash leftover
    /// (nothing is still writing it) and stays listed as usual.
    func refresh() {
        let cutoff = now()
        takes = store.listTakes(excluding: activeTakeIds)
            .filter { take in
                guard take.metadata.status == .recording else { return true }
                return cutoff.timeIntervalSince(take.sidecarModifiedAt) >= Self.recentRecordingGracePeriod
            }
            .map(RecoverableTake.init)
    }

    /// Run once at launch: prunes anything older than 14 days plus any
    /// orphaned file and any take over the aggregate disk cap, then loads
    /// whatever remains and logs a line — the menu item shows them, no modal.
    func pruneAndRefreshOnLaunch() {
        store.pruneOrphans()
        store.pruneOlderThan()
        store.enforceSizeCap()
        refresh()
        if !takes.isEmpty {
            NSLog("[Recovery] %d unrecovered dictation(s) found at launch", takes.count)
        }
    }

    /// Sends the recovered audio through the same speech sources as live dictation, saves the result
    /// to history with source "recovered", and puts the text on the
    /// clipboard (never auto-pastes — the original focus is gone).
    ///
    /// Rejects an already-busy take instead of letting two
    /// concurrent calls (menu + Settings, or a double activation) both read
    /// the PCM and issue two requests/history writes. Chunks a take over
    /// `DurableTranscriber.longRecordingThreshold` the same way the live
    /// Core path does instead of sending it whole and getting a
    /// permanent HTTP 413. The checkpoint is only deleted once `saveEntry`
    /// has actually succeeded — on failure it's marked `.failed` (with the
    /// error, surfaced by the recovery UI) and kept on disk: the text is
    /// still on the clipboard, but the required history entry never
    /// landed, so this must stay retryable rather than being thrown away.
    func transcribe(_ take: RecoverableTake) async {
        guard !busyTakeIds.contains(take.id) else { return }
        lastAlert = nil
        busyTakeIds.insert(take.id)
        defer {
            busyTakeIds.remove(take.id)
            refresh()
        }
        guard let rawData = try? Data(contentsOf: take.take.pcmURL), !rawData.isEmpty else {
            lastNotice = "That recording's audio file is missing or empty."
            store.delete(take.id)
            return
        }
        // Floor to a whole number of float32 frames — a write
        // that failed mid-flush can leave a trailing partial frame, and the
        // server's body-length check requires byteCount == frameCount * 4
        // exactly.
        let byteCount = (rawData.count / 4) * 4
        let sampleRate = max(take.take.metadata.sampleRate, 1)
        // Live dictation is levelled when the take ends; a saved one never was.
        let data = AudioCaptureService.levelled(Data(rawData.prefix(byteCount)), sampleRate: Double(sampleRate))
        let frameCount = byteCount / 4
        let header = AudioTakeHeader(
            sessionId: take.take.metadata.sessionId, sampleRate: sampleRate, frameCount: frameCount,
            durationSeconds: Double(frameCount) / Double(sampleRate), byteCount: byteCount
        )
        var audibleChunkWasEmpty = false
        do {
            // Chunks the same way the live Core path does — the
            // chunker is frame-based, so this is correct at any sample rate
            // (an Edge take's device rate, not just the Core's 16 kHz).
            let result = try await DurableTranscriber.transcribeStagesChunkingIfNeeded(header: header, data: Data(data)) { chunkHeader, chunkData in
                let chunkAudio = CapturedAudio(
                    data: chunkData, durationSeconds: chunkHeader.durationSeconds,
                    sampleRate: chunkHeader.sampleRate, frameCount: chunkHeader.frameCount
                )
                let chunkResult = try await self.transcribeAudio(chunkAudio)
                // A chunk with sound that comes back empty means words are missing.
                if chunkResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.isSilent(chunkData) {
                    audibleChunkWasEmpty = true
                }
                return (chunkResult.text, chunkResult.inferenceMs, chunkResult.rawText)
            }
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if audibleChunkWasEmpty && !trimmed.isEmpty {
                store.markStatus(take.id, status: .failed, errorMessage: "Part of the recording came back without words. It is kept so you can try again.")
                lastNotice = "Part of that recording could not be turned into text, so nothing was saved. The recording is kept so you can try again."
                return
            }
            guard !trimmed.isEmpty else {
                // Only a recording that is really silent is thrown away. If
                // there was sound, the engine failed or heard nothing: keep it.
                if Self.isSilent(data) {
                    lastNotice = "That recovered recording had no speech."
                    store.delete(take.id)
                } else {
                    store.markStatus(take.id, status: .failed, errorMessage: "No words came back. The recording is kept so you can try again.")
                    lastNotice = "No words came back from that recording. It is kept so you can try again."
                }
                return
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(trimmed, forType: .string)
            do {
                if let saveEntryWithStages {
                    try await saveEntryWithStages(trimmed, (result.rawText ?? result.text), header.durationSeconds, result.inferenceMs, "recovered")
                } else {
                    try await saveEntry(trimmed, header.durationSeconds, result.inferenceMs, "recovered")
                }
            } catch {
                store.markStatus(take.id, status: .failed, errorMessage: "Could not save to history: \(error.localizedDescription)")
                lastNotice = "Recovered dictation copied to the clipboard, but could not be saved to history: \(error.localizedDescription)"
                return
            }
            store.delete(take.id)
            lastNotice = "Recovered dictation copied to the clipboard."
        } catch {
            let alert = (error as? DictationFailure)?.alert ?? DictationAlert.speechConfigurationFailure(error)
            lastAlert = alert
            lastNotice = alert.map { "\($0.title). \($0.detail)" }
                ?? "Could not transcribe that recording: \(error.localizedDescription)"
            store.markStatus(take.id, status: .failed, errorMessage: lastNotice)
        }
    }

    /// True when every sample is effectively zero.
    static func isSilent(_ pcm: Data) -> Bool {
        DurableTranscriber.isSilent(pcm)
    }

    func discard(_ take: RecoverableTake) {
        store.delete(take.id)
        refresh()
    }
}
