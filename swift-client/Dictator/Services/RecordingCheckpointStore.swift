import Foundation

// Durable "recording checkpoints": while a dictation is in flight, both the
// mic-owner Edge (the raw capture) and the Core (the take it received) keep
// a copy of the audio on disk so a crash, a dropped connection, a failed
// `/transcribe`, or a recording longer than the server allows never silently
// loses the user's speech. This file is the shared, dependency-free store
// both sides use for that; the incremental writer the Edge's hot capture
// path drives lives in `RecordingCheckpointWriter.swift`.

/// Where a checkpoint's audio currently stands. Informational — cleanup
/// rules (see `EdgeRuntime`'s `applyCheckpointCleanup` and `DurableTranscriber`)
/// don't switch on this; presence of a take's files on disk is "unrecovered,"
/// because both sides delete a take's files the moment its outcome is known
/// to be safe.
enum CheckpointStatus: String, Codable, Equatable {
    /// Edge: still being appended to (or the app died before it finished).
    case recording
    /// Edge: capture stopped and the audio was handed off (sent to the Core,
    /// or the connection was lost trying) — see `RecordingCheckpointWriter.finish()`.
    case uploaded
    /// Edge: an engine/device restart cut this writer off mid-hold — it
    /// holds valid audio at its own declared sample rate up to the
    /// restart, but not the rest of the take (which either wasn't
    /// checkpointed, or continues under a fresh writer/take id). Always kept
    /// for recovery, like `.failed` — never auto-deleted by a session's own
    /// outcome cleanup, since its take id no longer matches that session's
    /// plain `edgeTakeId` (see `AudioCaptureService.interruptCheckpointSegment`).
    case interrupted
    /// Core: the full take was persisted before transcription started.
    case received
    /// Core: every retry attempt failed; kept for "retry from the menu."
    case failed
}

/// Sidecar JSON written next to `<takeId>.pcm`.
struct CheckpointMetadata: Codable, Equatable {
    var schemaVersion: Int = 1
    var takeId: String
    var sessionId: SessionID
    /// Sample rate of the raw float32 PCM in `<takeId>.pcm` — the Edge
    /// writes at the device rate (no resampling on the hot path), the Core
    /// writes at whatever `AudioTakeHeader.sampleRate` it received (16 kHz
    /// today).
    var sampleRate: Int
    var startedAt: Date
    /// Display name of the machine that recorded the audio (`EdgeRuntime.edgeName`
    /// for an Edge take, the mic owner's name for a Core take) — shown in the
    /// recovery UI's "machine" column.
    var edgeName: String
    var status: CheckpointStatus
    /// Set only when `status == .failed` — surfaced by the recovery UI.
    var errorMessage: String?

    init(
        takeId: String, sessionId: SessionID, sampleRate: Int, startedAt: Date = Date(),
        edgeName: String, status: CheckpointStatus, errorMessage: String? = nil
    ) {
        self.takeId = takeId
        self.sessionId = sessionId
        self.sampleRate = sampleRate
        self.startedAt = startedAt
        self.edgeName = edgeName
        self.status = status
        self.errorMessage = errorMessage
    }
}

/// One checkpoint as the recovery UI/`RecoveryService` sees it: metadata plus
/// the duration computed from the actual `.pcm` file size (never trusted from
/// the sidecar alone — a crash mid-flush would leave them disagreeing).
struct CheckpointTake: Identifiable, Equatable {
    var id: String { metadata.takeId }
    var metadata: CheckpointMetadata
    var durationSeconds: Double
    var pcmURL: URL
    /// The sidecar `.json`'s on-disk modification date — used by
    /// `RecoveryService.refresh()` to tell a still-being-written
    /// `.recording` checkpoint (last touched moments ago; a writer may still
    /// be mid-`finish()`) from a genuine crash leftover (untouched for a
    /// while) without needing any extra synchronization with the writer.
    var sidecarModifiedAt: Date
}

/// Append-only, dependency-free file store for recording checkpoints, used
/// identically by the Edge and the Core — the two roles never collide
/// because every take id they mint is prefixed (`edgeTakeId`/`coreTakeId`,
/// below), even though they can share the same process (standalone, or
/// Core with an attached local Edge) and therefore the same default
/// directory.
///
/// Every method here is synchronous and never throws: an I/O error is logged
/// and swallowed everywhere. This is recovery data, not the dictation path
/// itself — a failure here must never break dictation.
final class RecordingCheckpointStore {
    /// Days a recovery recording is kept before startup removes it.
    static let retentionDays = 14
    /// Default aggregate cap on the Recovery directory.
    static let defaultMaxBytes = 512 * 1_024 * 1_024

    private let directory: URL
    private let fileManager: FileManager
    private let maxBytes: Int

    init(directory: URL? = nil, fileManager: FileManager = .default, maxBytes: Int = RecordingCheckpointStore.defaultMaxBytes) {
        self.fileManager = fileManager
        self.maxBytes = maxBytes
        if let directory {
            self.directory = directory
        } else {
            // Under unit tests the default is a throwaway folder, never the
            // user's real Recovery folder.
            let underTest = NSClassFromString("XCTestCase") != nil
                || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            let base = (underTest ? nil : try? LocalSecret.applicationSupportDirectory())
                ?? fileManager.temporaryDirectory.appendingPathComponent("Dictator-\(underTest ? "Tests-\(ProcessInfo.processInfo.processIdentifier)" : "Support")", isDirectory: true)
            self.directory = base.appendingPathComponent("Recovery", isDirectory: true)
        }
        do {
            try fileManager.createDirectory(
                at: self.directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[Checkpoint] could not create Recovery directory: %@", error.localizedDescription)
        }
    }

    /// Take id for an Edge-side capture of `sessionId` — see
    /// `AudioCaptureService`/`EdgeRuntime`.
    static func edgeTakeId(_ sessionId: SessionID) -> String { "edge-\(sessionId)" }
    /// Take id for the Core's own retained copy of `sessionId`'s audio — see
    /// `DurableTranscriber`.
    static func coreTakeId(_ sessionId: SessionID) -> String { "core-\(sessionId)" }

    /// A take id is only ever minted internally (`edgeTakeId`/
    /// `coreTakeId`, optionally `-seg<n>` suffixed — see
    /// `AudioCaptureService.interruptCheckpointSegment`), but every method
    /// below that turns one into a file path guards against a corrupt or
    /// hostile value anyway: empty, or containing a path separator or `..`,
    /// is never valid.
    static func isValidTakeId(_ id: String) -> Bool {
        !id.isEmpty && !id.contains("/") && !id.contains("..")
    }

    // MARK: - Paths

    private func pcmURL(_ takeId: String) -> URL { directory.appendingPathComponent("\(takeId).pcm") }
    private func jsonURL(_ takeId: String) -> URL { directory.appendingPathComponent("\(takeId).json") }

    // MARK: - Edge incremental writer support

    /// Writes the initial `.recording` sidecar, then creates (or truncates)
    /// `<takeId>.pcm` and returns a `FileHandle` open for appending — or
    /// `nil` if either step failed (logged). The sidecar goes first, on
    /// purpose — `listTakes()` (and pruning) only ever discover a take
    /// through its `.json`, so a crash between the two writes must leave
    /// behind a sidecar pointing at a PCM that's merely empty (still
    /// discoverable, still harmless to delete), never a PCM with no sidecar
    /// at all (invisible to everything, leaked forever — see
    /// `pruneOrphans`). If the PCM step fails, the sidecar is rolled back
    /// rather than left behind pointing at nothing.
    /// `RecordingCheckpointWriter.init?` treats `nil` as "no checkpoint for
    /// this take," never as a reason to fail the capture itself.
    func beginRecording(takeId: String, sessionId: SessionID, sampleRate: Int, edgeName: String) -> FileHandle? {
        guard Self.isValidTakeId(takeId) else {
            NSLog("[Checkpoint] refusing invalid take id %@", takeId)
            return nil
        }
        writeMetadata(CheckpointMetadata(
            takeId: takeId, sessionId: sessionId, sampleRate: sampleRate, edgeName: edgeName, status: .recording
        ))
        let pcm = pcmURL(takeId)
        guard fileManager.createFile(atPath: pcm.path, contents: nil) else {
            NSLog("[Checkpoint] could not create %@", pcm.lastPathComponent)
            try? fileManager.removeItem(at: jsonURL(takeId))
            return nil
        }
        do {
            return try FileHandle(forWritingTo: pcm)
        } catch {
            NSLog("[Checkpoint] could not open %@ for writing: %@", pcm.lastPathComponent, error.localizedDescription)
            try? fileManager.removeItem(at: pcm)
            try? fileManager.removeItem(at: jsonURL(takeId))
            return nil
        }
    }

    // MARK: - Core one-shot save

    /// Persists an already-fully-received take in one write — the Core
    /// has the whole buffer already, so no incremental writer is needed.
    /// Sidecar first, same reasoning as `beginRecording` above.
    /// Enforces the aggregate disk cap once the write lands.
    func saveReceivedTake(takeId: String, sessionId: SessionID, sampleRate: Int, edgeName: String, data: Data) {
        guard Self.isValidTakeId(takeId) else {
            NSLog("[Checkpoint] refusing invalid take id %@", takeId)
            return
        }
        writeMetadata(CheckpointMetadata(
            takeId: takeId, sessionId: sessionId, sampleRate: sampleRate, edgeName: edgeName, status: .received
        ))
        do {
            try data.write(to: pcmURL(takeId), options: .atomic)
        } catch {
            NSLog("[Checkpoint] could not persist received take %@: %@", takeId, error.localizedDescription)
            // No PCM means nothing worth recovering — don't leave a sidecar
            // pointing at nothing.
            try? fileManager.removeItem(at: jsonURL(takeId))
            return
        }
        enforceSizeCap()
    }

    // MARK: - Status / lifecycle

    func markStatus(_ takeId: String, status: CheckpointStatus, errorMessage: String? = nil) {
        guard var metadata = readMetadata(takeId) else { return }
        metadata.status = status
        metadata.errorMessage = errorMessage
        writeMetadata(metadata)
    }

    /// Renames `<from>.pcm`/`<from>.json` to `<to>.pcm`/`<to>.json`, and
    /// rewrites the sidecar's own `takeId` field to match — used to give an
    /// engine-restart-interrupted segment its own take id so it stops
    /// colliding with (being deleted or kept by) whatever the
    /// session's own outcome cleanup does with the plain `edgeTakeId`.
    /// Best-effort like everything else here: on any I/O failure this logs
    /// and leaves the original files in place under `from`.
    func rename(_ from: String, to: String) {
        guard Self.isValidTakeId(from), Self.isValidTakeId(to) else {
            NSLog("[Checkpoint] refusing to rename invalid take id %@ -> %@", from, to)
            return
        }
        // The new sidecar goes first: at every step a crash leaves a complete
        // take under one name or the other, which `pruneOrphans` then tidies.
        if var metadata = readMetadata(from) {
            metadata.takeId = to
            writeMetadata(metadata)
        }
        do {
            if fileManager.fileExists(atPath: pcmURL(from).path) {
                try fileManager.moveItem(at: pcmURL(from), to: pcmURL(to))
            }
            try? fileManager.removeItem(at: jsonURL(from))
        } catch {
            NSLog("[Checkpoint] could not rename %@ to %@: %@", from, to, error.localizedDescription)
            try? fileManager.removeItem(at: jsonURL(to))
        }
    }

    /// Removes both files for `takeId`, if present — and its edge-/core-
    /// sibling for the same session, if it still has a sidecar to find it
    /// by. A session that failed can retain both copies (the
    /// prefixes exist only to avoid a filename collision, not to make them
    /// independently recoverable); discarding or recovering either one
    /// should discard both, not leave the other to be offered again. Safe
    /// to call on a take that's already gone (or never existed).
    ///
    /// The sibling cascade only fires for the canonical `edge-<session>`/
    /// `core-<session>` pair — a `takeId` with any other shape (e.g. an
    /// engine-restart-interrupted `-seg<n>` segment) is a
    /// genuinely distinct take and must never drag the session's real
    /// edge-/core- checkpoint down with it.
    func delete(_ takeId: String) {
        if let sessionId = readMetadata(takeId)?.sessionId,
           takeId == Self.edgeTakeId(sessionId) || takeId == Self.coreTakeId(sessionId) {
            let sibling = takeId.hasPrefix("core-") ? Self.edgeTakeId(sessionId) : Self.coreTakeId(sessionId)
            try? fileManager.removeItem(at: pcmURL(sibling))
            try? fileManager.removeItem(at: jsonURL(sibling))
        }
        try? fileManager.removeItem(at: pcmURL(takeId))
        try? fileManager.removeItem(at: jsonURL(takeId))
    }

    /// Removes `takeId` alone. For when one copy has served its purpose but
    /// its sibling is still the way back to the recording.
    func deleteLeavingSibling(_ takeId: String) {
        try? fileManager.removeItem(at: pcmURL(takeId))
        try? fileManager.removeItem(at: jsonURL(takeId))
    }

    // MARK: - Listing / recovery

    /// Every take still on disk, excluding `active` take ids (sessions
    /// currently in flight on this machine), newest first. Presence on disk
    /// is "unrecovered" — both the Edge and the Core delete a take's files
    /// the instant its outcome is known to be safe (see `EdgeRuntime`'s
    /// cleanup and `DurableTranscriber`'s), so a leftover file of any
    /// `status` means something between the mic and history didn't finish.
    ///
    /// A sidecar whose own `takeId` doesn't match its filename
    /// is skipped (and logged) rather than trusted — acting on the claimed
    /// id instead of the filename it actually lives at is exactly how a
    /// corrupt sidecar can make `discard`/recovery delete the wrong take.
    ///
    /// When two takes share a `sessionId` under the canonical
    /// `edge-<session>`/`core-<session>` ids (a standalone failure keeps
    /// both), only the `core-` one is returned — it's already 16 kHz, the
    /// exact bytes that were sent — so the recovery UI never shows the same
    /// dictation twice. A take whose id isn't one of those two exact ids
    /// (e.g. an engine-restart-interrupted `-seg<n>` segment) is
    /// a genuinely distinct take sharing that `sessionId` for a different
    /// reason, and is never collapsed by this.
    func listTakes(excluding active: Set<String> = []) -> [CheckpointTake] {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return [] }
        let takeIds = names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) }
        var all: [CheckpointTake] = []
        for takeId in takeIds where !active.contains(takeId) && Self.isValidTakeId(takeId) {
            guard let metadata = readMetadata(takeId) else { continue }
            guard metadata.takeId == takeId else {
                NSLog("[Checkpoint] sidecar %@ claims takeId %@ — skipping (mismatched id)", takeId, metadata.takeId)
                continue
            }
            let pcm = pcmURL(takeId)
            let json = jsonURL(takeId)
            let byteCount = ((try? fileManager.attributesOfItem(atPath: pcm.path))?[.size] as? Int) ?? 0
            let duration = Double(byteCount) / 4 / Double(max(metadata.sampleRate, 1))
            let sidecarModifiedAt = ((try? fileManager.attributesOfItem(atPath: json.path))?[.modificationDate] as? Date) ?? metadata.startedAt
            all.append(CheckpointTake(metadata: metadata, durationSeconds: duration, pcmURL: pcm, sidecarModifiedAt: sidecarModifiedAt))
        }

        var bySession: [SessionID: CheckpointTake] = [:]
        var others: [CheckpointTake] = []
        for take in all {
            let isCanonicalPair = take.id == Self.edgeTakeId(take.metadata.sessionId) || take.id == Self.coreTakeId(take.metadata.sessionId)
            guard isCanonicalPair else {
                others.append(take)
                continue
            }
            if let existing = bySession[take.metadata.sessionId] {
                if take.id.hasPrefix("core-") || !existing.id.hasPrefix("core-") {
                    bySession[take.metadata.sessionId] = take
                }
            } else {
                bySession[take.metadata.sessionId] = take
            }
        }
        return (Array(bySession.values) + others).sorted { $0.metadata.startedAt > $1.metadata.startedAt }
    }

    /// Deletes any take started more than `days` ago (default 14), run once
    /// at launch — a take the recovery UI's Discard never got clicked on
    /// shouldn't accumulate forever.
    func pruneOlderThan(days: Int = RecordingCheckpointStore.retentionDays, referenceDate: Date = Date()) {
        let cutoff = referenceDate.addingTimeInterval(-Double(days) * 86_400)
        for take in listTakes() where take.metadata.startedAt < cutoff {
            delete(take.metadata.takeId)
        }
    }

    /// Deletes a `.pcm` with no matching `.json` sidecar (left by a build that wrote the PCM first) and a
    /// `.json` sidecar that fails to decode (truncated/corrupt write) — both are otherwise invisible to
    /// `listTakes()`, which only ever starts from a successfully-decoded `.json`, and would leak forever.
    /// Run once at launch, alongside `pruneOlderThan`. Logged, never silent.
    func pruneOrphans() {
        guard let names = try? fileManager.contentsOfDirectory(atPath: directory.path) else { return }
        let jsonBaseNames = Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(".json".count)) })
        let pcmBaseNames = Set(names.filter { $0.hasSuffix(".pcm") }.map { String($0.dropLast(".pcm".count)) })

        for takeId in pcmBaseNames.subtracting(jsonBaseNames) {
            NSLog("[Checkpoint] deleting orphan PCM with no sidecar: %@", takeId)
            try? fileManager.removeItem(at: pcmURL(takeId))
        }
        for takeId in jsonBaseNames {
            guard readMetadata(takeId) != nil else {
                NSLog("[Checkpoint] deleting sidecar that failed to decode: %@", takeId)
                try? fileManager.removeItem(at: jsonURL(takeId))
                try? fileManager.removeItem(at: pcmURL(takeId))
                continue
            }
            if !pcmBaseNames.contains(takeId) {
                NSLog("[Checkpoint] deleting sidecar with no audio: %@", takeId)
                try? fileManager.removeItem(at: jsonURL(takeId))
            }
        }
    }

    /// Caps the Recovery directory's total size. Called after
    /// every write that could grow it (`RecordingCheckpointWriter.finish()`,
    /// `saveReceivedTake` above) and once at launch (`pruneOlderThan`'s
    /// caller) — deletes the oldest takes (by `startedAt`) first until the
    /// aggregate is back under `maxBytes`, so a long run of failed takes
    /// can't consume unbounded disk between 14-day age prunes.
    func enforceSizeCap() {
        let takes = listTakes().sorted { $0.metadata.startedAt < $1.metadata.startedAt } // oldest first
        var total = takes.reduce(0) { $0 + sizeOnDisk($1) }
        guard total > maxBytes else { return }
        // A take still being recorded is the one thing here that isn't over.
        for take in takes where take.metadata.status != .recording {
            guard total > maxBytes else { break }
            total -= sizeOnDisk(take)
            delete(take.metadata.takeId)
        }
    }

    /// `listTakes` shows one of an edge-/core- pair and `delete` removes
    /// both, so the size has to count both.
    private func sizeOnDisk(_ take: CheckpointTake) -> Int {
        let session = take.metadata.sessionId
        var ids = [take.id]
        if take.id == Self.edgeTakeId(session) { ids.append(Self.coreTakeId(session)) }
        if take.id == Self.coreTakeId(session) { ids.append(Self.edgeTakeId(session)) }
        return ids.flatMap { [pcmURL($0), jsonURL($0)] }.reduce(0) {
            $0 + (((try? fileManager.attributesOfItem(atPath: $1.path))?[.size] as? Int) ?? 0)
        }
    }

    // MARK: - Metadata I/O

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func readMetadata(_ takeId: String) -> CheckpointMetadata? {
        guard let data = try? Data(contentsOf: jsonURL(takeId)) else { return nil }
        return try? Self.decoder.decode(CheckpointMetadata.self, from: data)
    }

    private func writeMetadata(_ metadata: CheckpointMetadata) {
        do {
            let data = try Self.encoder.encode(metadata)
            try data.write(to: jsonURL(metadata.takeId), options: .atomic)
        } catch {
            NSLog("[Checkpoint] could not write metadata for %@: %@", metadata.takeId, error.localizedDescription)
        }
    }
}
