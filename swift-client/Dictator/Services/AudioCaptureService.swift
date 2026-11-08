import AVFoundation
import Accelerate
import AudioToolbox
import CoreAudio
import Foundation

/// Always-on audio capture using AVAudioEngine. The stream stays open; start/stop
/// toggles buffer accumulation. Avoids Core Audio session-startup cost (~100ms)
/// per press.
final class AudioCaptureService {
    static let targetSampleRate: Double = 16000

    /// Replaced (never reused) after a start fails: an engine that went
    /// through a Core Audio configuration change can stay unable to start
    /// for as long as the process lives, so retrying the same instance
    /// every few seconds never recovers.
    private var engine = AVAudioEngine()
    /// Set when a start attempt fails; the next attempt builds a fresh
    /// `AVAudioEngine` first. Any hold in progress was already finalized as
    /// its own recoverable segment by `stopEngine(preserveCapture: true)`.
    private var needsFreshEngine = false
    /// How many engines this service has replaced — for diagnostics/tests.
    private(set) var engineReplacementCount = 0
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var isCapturing = false
    var isCaptureActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCapturing
    }
    private var isEngineRunning = false
    private var tapInstalled = false
    private var needsConfigurationRecovery = false
    private var configurationObserver: NSObjectProtocol?
    private var captureStartTime: Date?
    private(set) var activeDeviceUID = ""
    /// Last time a level was forwarded to `onLevel` (audio-thread only).
    private var lastLevelDispatch: CFTimeInterval = 0

    /// Called on the main queue with normalized RMS (~0...1) while capturing.
    var onLevel: ((Float) -> Void)?

    /// Durable recording checkpoints. Shared with `EdgeRuntime`, which uses
    /// it to clean up a session's checkpoint by outcome — see
    /// `checkpointStore` there.
    let checkpointStore: RecordingCheckpointStore
    /// How much new audio must accumulate before a checkpoint flush (~3s;
    /// tests use a tiny value so a couple of small buffers already trigger
    /// a flush).
    var checkpointFlushIntervalSeconds: TimeInterval
    private var checkpointWriter: RecordingCheckpointWriter?
    /// Off the audio tap thread: every checkpoint write happens here, never
    /// inline in `handleAudioBuffer`.
    private let checkpointQueue = DispatchQueue(label: "dev.noamlitt.dictator.audio-checkpoint", qos: .utility)
    /// Bumped by every `startCapture` — a buffer whose tap
    /// callback observed an earlier generation (paused, then resumed after
    /// a stop/start boundary) is identified as stale by comparing against
    /// this rather than trusting `isCapturing` alone, which can't tell
    /// session A's hold from session B's.
    private(set) var captureGeneration = 0
    /// Session/edge-name this capture started for — retained (not just a
    /// `startCapture` parameter) so the engine-restart resume can
    /// open a fresh writer for the same take without the caller having to
    /// re-supply them.
    private var currentSessionId: SessionID?
    private var currentEdgeName = ""
    /// How many times this session's checkpoint has been
    /// interrupted by an engine/device restart — used to mint each
    /// interrupted segment's own take id (`<edgeTakeId>-seg<n>`). Reset by
    /// every `startCapture`.
    private var checkpointSegmentIndex = 0

    /// Test-only override for the sample rate `startCapture`/engine-restart
    /// resume treat as "the device rate" — lets `AudioCaptureServiceTests`
    /// exercise the checkpoint path deterministically without depending on
    /// whatever audio hardware happens to be attached to the test host.
    var sampleRateOverrideForTesting: Double?

    var deviceSampleRate: Double {
        sampleRateOverrideForTesting ?? engine.inputNode.inputFormat(forBus: 0).sampleRate
    }

    init(checkpointStore: RecordingCheckpointStore = RecordingCheckpointStore(), checkpointFlushIntervalSeconds: TimeInterval = 3) {
        self.checkpointStore = checkpointStore
        self.checkpointFlushIntervalSeconds = checkpointFlushIntervalSeconds
        observeConfigurationChanges()
    }

    private func observeConfigurationChanges() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.needsConfigurationRecovery = true
            HotkeyService.recordDiagnostics("audio configuration changed; recovery scheduled")
        }
    }

    /// Swaps in a brand-new `AVAudioEngine`. Only called while the old one
    /// is fully stopped (no tap, not running), so nothing in flight still
    /// refers to it except stale tap callbacks, which `captureGeneration`
    /// already discards.
    func replaceEngine() {
        if isEngineRunning || tapInstalled || engine.isRunning {
            stopEngine(preserveCapture: true)
        }
        engine = AVAudioEngine()
        engineReplacementCount += 1
        needsFreshEngine = false
        observeConfigurationChanges()
        HotkeyService.recordDiagnostics("audio engine replaced count=\(engineReplacementCount)")
    }

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Start the audio engine (always-on). Call once at app launch.
    func startEngine(deviceUID: String = "") throws {
        let requestedUID = deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(isEngineRunning && engine.isRunning && tapInstalled
                && !needsConfigurationRecovery && activeDeviceUID == requestedUID) else { return }

        if needsFreshEngine {
            replaceEngine()
        } else if isEngineRunning || tapInstalled || needsConfigurationRecovery || activeDeviceUID != requestedUID {
            stopEngine(preserveCapture: true)
        }
        // Until this attempt succeeds, the next one starts from a new engine.
        needsFreshEngine = true

        let inputNode = engine.inputNode
        if !requestedUID.isEmpty {
            let deviceID = try Self.audioDeviceID(forUID: requestedUID)
            guard let audioUnit = inputNode.audioUnit else {
                throw AudioCaptureError.cannotSelectInputDevice(requestedUID)
            }
            var mutableDeviceID = deviceID
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard status == noErr else {
                throw AudioCaptureError.cannotSelectInputDevice(requestedUID)
            }
        }

        let format = inputNode.inputFormat(forBus: 0)

        guard format.sampleRate > 0 else {
            throw AudioCaptureError.noInputDevice
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.handleAudioBuffer(buffer)
        }
        tapInstalled = true

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
        isEngineRunning = true
        needsConfigurationRecovery = false
        needsFreshEngine = false
        activeDeviceUID = requestedUID
        let selectedDeviceLabel = requestedUID.isEmpty ? "system-default" : requestedUID
        HotkeyService.recordDiagnostics(
            "audio start ok selectedUID=\(selectedDeviceLabel) "
            + "sampleRate=\(Int(format.sampleRate))"
        )
        // If a hold was still in progress across this restart
        // (`stopEngine(preserveCapture: true)` above already finalized the
        // previous segment as `.interrupted`), pick the checkpoint back up
        // at the new device's rate rather than leaving the rest of the hold
        // uncheckpointed.
        resumeCheckpointSegmentIfNeeded()
    }

    /// Repairs an engine stopped by sleep, device reconnects, or Core Audio
    /// configuration changes. Also applies a newly selected microphone without
    /// requiring the app to be relaunched.
    @discardableResult
    func ensureRunning(deviceUID: String) throws -> Bool {
        let requestedUID = deviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        let healthy = isEngineRunning && engine.isRunning && tapInstalled
            && !needsConfigurationRecovery && activeDeviceUID == requestedUID
        guard !healthy else { return false }
        try startEngine(deviceUID: requestedUID)
        return true
    }

    /// Begin accumulating audio frames. `sessionId`/`edgeName` (when given)
    /// also open a durable recording checkpoint for this take — see
    /// `RecordingCheckpointStore`. Omitting `sessionId` (a Teach take)
    /// just means no checkpoint is written.
    func startCapture(sessionId: SessionID? = nil, edgeName: String = "") {
        lock.lock()
        buffers.removeAll()
        isCapturing = true
        captureStartTime = Date()
        captureGeneration += 1
        let generation = captureGeneration
        lock.unlock()

        currentSessionId = sessionId
        currentEdgeName = edgeName
        checkpointSegmentIndex = 0

        guard let sessionId else { return }
        let sampleRate = Int(deviceSampleRate)
        guard sampleRate > 0 else { return }
        beginCheckpointWriter(
            takeId: RecordingCheckpointStore.edgeTakeId(sessionId), sessionId: sessionId,
            sampleRate: sampleRate, edgeName: edgeName, generation: generation
        )
    }

    /// Shared by `startCapture` and `resumeCheckpointSegmentIfNeeded` —
    /// both install a fresh writer for `sessionId`'s take,
    /// stamped with the `generation` this capture (or capture segment)
    /// belongs to.
    private func beginCheckpointWriter(takeId: String, sessionId: SessionID, sampleRate: Int, edgeName: String, generation: Int) {
        let flushInterval = checkpointFlushIntervalSeconds
        checkpointQueue.async { [weak self] in
            guard let self else { return }
            self.checkpointWriter = RecordingCheckpointWriter(
                store: self.checkpointStore,
                takeId: takeId,
                sessionId: sessionId,
                sampleRate: sampleRate,
                edgeName: edgeName,
                flushIntervalSeconds: flushInterval,
                generation: generation
            )
        }
    }

    /// Stop accumulating and return the captured audio as 16kHz mono float32 Data.
    func stopCapture() -> CapturedAudio? {
        lock.lock()
        isCapturing = false
        let captured = buffers
        let startTime = captureStartTime
        buffers = []
        captureStartTime = nil
        lock.unlock()

        finalizeCheckpoint()

        guard !captured.isEmpty, let startTime else { return nil }

        let duration = Date().timeIntervalSince(startTime)
        guard let picked = Self.monoTake(from: captured) else { return nil }
        let sourceRate = deviceSampleRate
        let mono = Self.normalized(picked, sampleRate: sourceRate)

        let resampled = Self.resampleTo16kHz(mono.samples, from: sourceRate)
        let frameCount = resampled.count / 4 // float32 = 4 bytes
        let ranking = mono.channelRanking
            .map { "ch\($0.channel)=\(String(format: "%.0f", $0.sustainedDBFS))/\(Int($0.activeFraction * 100))%" }
            .joined(separator: ",")
        HotkeyService.recordDiagnostics(
            "capture take: duration=\(String(format: "%.1f", duration))s sourceRate=\(Int(sourceRate)) "
            + "channels=\(mono.channelCount) used=\(mono.channelLabel) ranking=[\(ranking)] "
            + "rms=\(String(format: "%.1f", mono.rmsDBFS))dBFS peak=\(String(format: "%.1f", mono.peakDBFS))dBFS "
            + "gain=+\(String(format: "%.1f", mono.gainDB))dB limited=\(String(format: "%.1f", mono.limitedDB))dB frames16k=\(frameCount)"
        )
        return CapturedAudio(
            data: resampled,
            durationSeconds: duration,
            sampleRate: Int(Self.targetSampleRate),
            frameCount: frameCount
        )
    }

    /// Cancel the active capture, discard buffer and its on-disk checkpoint
    /// (a genuine user cancel / no-audio take is worthless — nothing to
    /// recover).
    func cancelCapture() {
        lock.lock()
        isCapturing = false
        buffers.removeAll()
        captureStartTime = nil
        lock.unlock()

        discardCheckpoint()
    }

    /// Stops accumulating without discarding the on-disk checkpoint — used
    /// only when a transport/connection loss makes normal completion
    /// impossible. Unlike `cancelCapture()`, the checkpoint stays on disk for
    /// the recovery UI.
    func abandonCapture() {
        lock.lock()
        isCapturing = false
        buffers.removeAll()
        captureStartTime = nil
        lock.unlock()

        finalizeCheckpoint()
    }

    private func finalizeCheckpoint() {
        checkpointQueue.async { [weak self] in
            self?.checkpointWriter?.finish()
            self?.checkpointWriter = nil
        }
    }

    private func discardCheckpoint() {
        checkpointQueue.async { [weak self] in
            self?.checkpointWriter?.discard()
            self?.checkpointWriter = nil
        }
    }

    /// Routes a checkpoint deletion through the same serial
    /// `checkpointQueue` that `finish()`/`discard()`/`appendToCheckpoint`
    /// already run on, instead of the caller (`EdgeRuntime`'s outcome
    /// cleanup) calling `checkpointStore.delete` directly on the main actor.
    /// Without this, a delete triggered by the terminal-outcome broadcast
    /// could run before a still-in-flight `finish()` for the very same take
    /// reaches the front of this queue — `finish()`'s final flush + status
    /// write would then resurrect the files cleanup just removed. Queuing
    /// the delete here instead guarantees it only ever runs after any
    /// `finish()`/`discard()` already queued for this take.
    func deleteCheckpoint(takeId: String) {
        checkpointQueue.async { [weak self] in
            self?.checkpointStore.delete(takeId)
        }
    }

    // MARK: - Test-only seams

    /// Blocks until every checkpoint-queue operation enqueued so far has
    /// finished — `startCapture`/`stopCapture`/`finishHandlingAudioBuffer`/
    /// etc. all do their checkpoint I/O asynchronously off the tap thread
    /// (see `checkpointQueue`), so `AudioCaptureServiceTests` needs a way to
    /// synchronize with that before asserting on `checkpointStore`.
    func drainCheckpointQueueForTesting() {
        checkpointQueue.sync {}
    }

    /// The in-RAM `buffers` count — `AudioCaptureServiceTests` uses this to
    /// confirm a stale-generation buffer was dropped rather than
    /// appended.
    var capturedBufferCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffers.count
    }

    func stopEngine(preserveCapture: Bool = false) {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning {
            engine.stop()
        }
        isEngineRunning = false
        needsConfigurationRecovery = false
        activeDeviceUID = ""

        if preserveCapture {
            lock.lock()
            let capturing = isCapturing
            if capturing {
                // Buffers from two devices/sample rates cannot be combined
                // safely. Continue the hold from the recovered device.
                buffers.removeAll()
                captureStartTime = Date()
                // A new segment starts here too — any tap buffer
                // from the old engine that's still in flight must never be
                // appended to what comes next.
                captureGeneration += 1
            }
            lock.unlock()

            if capturing {
                interruptCheckpointSegment()
            }
        }
    }

    /// Called from `stopEngine(preserveCapture: true)` when a
    /// hold was in progress across an engine/device restart. The writer
    /// so far recorded valid audio at its own (pre-restart) sample rate —
    /// letting it keep appending post-restart samples under that same
    /// label would silently make the file's declared rate false for
    /// everything after this point. Finalize it as its own, separately
    /// recoverable segment instead: `.interrupted` (not `.uploaded`)
    /// documents why it stops short of the full hold, and giving it its
    /// own `-seg<n>` take id (rather than the session's plain `edgeTakeId`)
    /// means the session's own outcome-based cleanup (`EdgeRuntime`'s
    /// `applyCheckpointCleanup`, keyed on `edgeTakeId`) can never delete
    /// it — nor, for that matter, know to keep it either; it's simply its
    /// own take from here on, listed in recovery like any other. The
    /// remainder of the hold after this point is captured in RAM as usual
    /// (`buffers`, cleared just above) but is not checkpointed — only
    /// `resumeCheckpointSegmentIfNeeded()` succeeding (the restart worked)
    /// resumes checkpointing it, under a fresh writer.
    private func interruptCheckpointSegment() {
        checkpointQueue.async { [weak self] in
            guard let self, let writer = self.checkpointWriter else { return }
            writer.finish(status: .interrupted)
            self.checkpointSegmentIndex += 1
            let segmentId = "\(writer.takeId)-seg\(self.checkpointSegmentIndex)"
            self.checkpointStore.rename(writer.takeId, to: segmentId)
            self.checkpointWriter = nil
        }
    }

    /// After a successful engine/device restart, if a hold was
    /// still in progress (`interruptCheckpointSegment` above already ran),
    /// start a fresh writer for the rest of it — at the new device's rate,
    /// under the session's plain `edgeTakeId` again (this is "the"
    /// checkpoint for the current hold once more, exactly as if it had
    /// started fresh from here; the interrupted segment before it is a
    /// separate, independently recoverable take). A restart that instead
    /// fails (no device, permission lost) never reaches this — the hold
    /// simply goes uncheckpointed for its remainder, same as if checkpoints
    /// didn't exist, and `buffers` (in RAM) is all `stopCapture()` has to
    /// work with when it eventually stops. Internal (not private) so
    /// `AudioCaptureServiceTests` can drive it directly, without needing a
    /// real `engine.start()` to succeed on the test host.
    func resumeCheckpointSegmentIfNeeded() {
        lock.lock()
        let capturing = isCapturing
        let generation = captureGeneration
        lock.unlock()
        guard capturing, let sessionId = currentSessionId else { return }
        let sampleRate = Int(deviceSampleRate)
        guard sampleRate > 0 else { return }
        beginCheckpointWriter(
            takeId: RecordingCheckpointStore.edgeTakeId(sessionId), sessionId: sessionId,
            sampleRate: sampleRate, edgeName: currentEdgeName, generation: generation
        )
    }

    // MARK: - Checkpoint (always called on `checkpointQueue`)

    /// Reduces `buffer` to mono float32 at its native (device) sample
    /// rate — deliberately not resampled to 16kHz, so the checkpoint path
    /// never costs more than the dispatch in `handleAudioBuffer`.
    /// `generation` is the value `handleAudioBuffer` captured when this
    /// specific buffer's tap callback fired; if a stop/start (or an
    /// engine-restart segment boundary) has since installed a different
    /// writer, this generation no longer matches `checkpointWriter?.generation` and the
    /// buffer is dropped rather than appended into the wrong take.
    private func appendToCheckpoint(_ buffer: AVAudioPCMBuffer, generation: Int) {
        guard let writer = checkpointWriter, writer.generation == generation else { return }
        writer.append(Self.checkpointSamples(buffer))
    }

    /// Every channel summed. The best channel can't be known until the take
    /// ends, and an average would divide the microphone by the channel count:
    /// 26 dB on a 20-channel interface. Float samples can't clip, and
    /// `levelled` brings a recovered take to the right level.
    static func checkpointSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let frameCount = Int(buffer.frameLength)
        var samples = [Float](repeating: 0, count: frameCount)
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<frameCount { samples[frame] += channelData[channel][frame] }
        }
        return samples
    }

    // MARK: - Private

    /// Split into `beginHandlingAudioBuffer` (reads the state a
    /// buffer observed "at tap time," before any pause) and
    /// `finishHandlingAudioBuffer` (re-validates that state atomically with
    /// the actual append) so a tap callback that gets preempted between the
    /// two — in production a genuine scheduling race; in
    /// `AudioCaptureServiceTests` a deliberately delayed callback driven by
    /// hand — can never contaminate a different capture generation's
    /// `buffers`/checkpoint. Internal (not private), like `wireHotkey`/
    /// `wirePointerPresence` elsewhere in this file's sibling `EdgeRuntime`,
    /// for exactly that reason.
    func handleAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let generation = beginHandlingAudioBuffer() else { return }
        let copy = buffer.copy() as! AVAudioPCMBuffer
        finishHandlingAudioBuffer(copy, generation: generation)
    }

    /// Reads `(isCapturing, captureGeneration)` once, under the lock —
    /// nothing else is touched. Returns `nil` when not currently capturing
    /// (nothing to do).
    func beginHandlingAudioBuffer() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        return isCapturing ? captureGeneration : nil
    }

    /// Re-validates `generation` against current state and appends `copy`
    /// to `buffers` atomically, under one lock hold — so nothing can change
    /// between the check and the mutation. A generation mismatch (or
    /// capture having stopped outright since `beginHandlingAudioBuffer` ran)
    /// means the session/segment this buffer was captured under is already
    /// gone; silently drop it rather than contaminate whatever is capturing
    /// now.
    func finishHandlingAudioBuffer(_ copy: AVAudioPCMBuffer, generation: Int) {
        lock.lock()
        let stillValid = isCapturing && captureGeneration == generation
        if stillValid {
            buffers.append(copy)
        }
        lock.unlock()
        guard stillValid else { return }

        // Off the tap thread: the dispatch itself is the only
        // cost paid here. `copy` is never mutated after this point (the RAM
        // accumulation above only ever appends), so sharing it with the
        // checkpoint queue is safe. `appendToCheckpoint` re-checks
        // `generation` again once it actually runs — a writer
        // install/rename that raced ahead of this dispatch is still caught
        // there even though the RAM-side check above already passed.
        checkpointQueue.async { [weak self] in
            self?.appendToCheckpoint(copy, generation: generation)
        }

        if let onLevel, let channelData = copy.floatChannelData {
            // Coalesce level updates to ~30 Hz. The tap delivers ~47 buffers/s
            // (1024 frames @ 48 kHz); forwarding every one re-renders the
            // waveform indicator on the main run loop that fast, pressuring the
            // CGEvent hotkey tap that lives on the same run loop and risking a
            // dropped Right-Option release — which left recording stuck on.
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastLevelDispatch >= 1.0 / 30 {
                lastLevelDispatch = now
                let frameCount = vDSP_Length(copy.frameLength)
                var rms: Float = 0
                vDSP_rmsqv(channelData[0], 1, &rms, frameCount)
                DispatchQueue.main.async { onLevel(rms) }
            }
        }
    }

    private static func audioDeviceID(forUID wantedUID: String) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var byteCount: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &byteCount
        ) == noErr else {
            throw AudioCaptureError.inputDeviceUnavailable(wantedUID)
        }

        var devices = [AudioDeviceID](
            repeating: kAudioObjectUnknown,
            count: Int(byteCount) / MemoryLayout<AudioDeviceID>.size
        )
        let deviceStatus = devices.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return OSStatus(kAudio_ParamError) }
            return AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &byteCount,
                baseAddress
            )
        }
        guard deviceStatus == noErr else {
            throw AudioCaptureError.inputDeviceUnavailable(wantedUID)
        }

        var uidAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        for deviceID in devices {
            var unmanagedUID: Unmanaged<CFString>?
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let status = AudioObjectGetPropertyData(
                deviceID, &uidAddress, 0, nil, &uidSize, &unmanagedUID
            )
            if status == noErr,
               let uid = unmanagedUID?.takeUnretainedValue(),
               uid as String == wantedUID {
                return deviceID
            }
        }
        throw AudioCaptureError.inputDeviceUnavailable(wantedUID)
    }

    /// The mono take handed to the recogniser, plus what was decided about it
    /// (logged per take so a garbled result is diagnosable afterwards).
    struct MonoTake {
        var samples: [Float]
        var channelCount: Int
        /// "mono", "ch3", "ch1+2", … — the channels that were used.
        var channelLabel: String
        /// Per-channel sustained level (median 10 ms frame level, dBFS) and
        /// the fraction of frames carrying signal, best first, top four.
        var channelRanking: [(channel: Int, sustainedDBFS: Float, activeFraction: Float)]
        /// Level of the selected mono signal before normalization.
        var rmsDBFS: Float
        var peakDBFS: Float
        /// Gain applied by `normalized`, in dB (0 when nothing was needed).
        var gainDB: Float = 0
        /// Deepest gain reduction the limiter applied, in dB (0 = none).
        var limitedDB: Float = 0
    }

    /// Channels within this many dB of the best one (by sustained level)
    /// are treated as carrying the microphone too and averaged.
    static let channelSelectionWindowDB: Float = 6
    /// A channel is eligible only if at least this fraction of its 10 ms
    /// frames carry signal above `activeFrameFloorDBFS`. A loopback pair
    /// that records the Mac's own output holds a loud 50 ms beep and
    /// digital silence otherwise: high RMS, near-zero active fraction.
    static let minimumActiveFraction: Float = 0.2
    static let activeFrameFloorDBFS: Float = -75
    /// Level the recogniser is fed at. Takes 40 dB below this came back as
    /// sound-alike nonsense. -20 dBFS RMS is ordinary close-mic speech.
    static let targetRMSDBFS: Float = -20
    /// Never boost more than this: a silent or unplugged input must not be
    /// turned into full-scale hiss.
    static let maximumGainDB: Float = 36
    static let peakCeilingDBFS: Float = -1
    /// Limiter release: how fast gain recovers after a peak.
    static let limiterReleaseSeconds: Double = 0.05

    private static let analysisFrameSeconds = 0.01

    /// Concatenates the tap's buffers and reduces them to one channel.
    ///
    /// Multi-channel interfaces expose every input as one stream (a
    /// Scarlett 18i8 shows up as 20 channels): the microphone on one,
    /// mirrors or loopback of the Mac's output on others, nothing on the
    /// rest. Averaging all of them would divide the mic by the channel count,
    /// and ranking by plain RMS would pick a loopback pair whose only content
    /// is the app's own start beep. So each channel is scored by its
    /// sustained level — the median of its 10 ms frame levels — and must
    /// carry signal in at least `minimumActiveFraction` of frames; the
    /// best channel and any within `channelSelectionWindowDB` of it are
    /// averaged.
    static func monoTake(from buffers: [AVAudioPCMBuffer]) -> MonoTake? {
        guard let first = buffers.first(where: { $0.floatChannelData != nil }) else { return nil }
        let channelCount = max(1, Int(first.format.channelCount))
        let sampleRate = first.format.sampleRate
        var channels = [[Float]](repeating: [], count: channelCount)
        for buffer in buffers {
            guard let channelData = buffer.floatChannelData else { continue }
            let frameCount = Int(buffer.frameLength)
            let available = min(channelCount, Int(buffer.format.channelCount))
            for ch in 0..<channelCount {
                let source = ch < available ? ch : 0
                channels[ch].append(contentsOf: UnsafeBufferPointer(start: channelData[source], count: frameCount))
            }
        }
        guard let frameCount = channels.first?.count, frameCount > 0 else { return nil }

        let frameLength = max(1, Int(sampleRate * analysisFrameSeconds))
        struct Score { var sustained: Float; var active: Float }
        let scores: [Score] = channels.map { channel in
            let levels = frameLevelsDBFS(channel, frameLength: frameLength)
            let sorted = levels.sorted()
            let median = sorted.isEmpty ? -180 : sorted[sorted.count / 2]
            let active = levels.isEmpty ? 0 : Float(levels.filter { $0 > activeFrameFloorDBFS }.count) / Float(levels.count)
            return Score(sustained: median, active: active)
        }
        let ranked = scores.enumerated().sorted { $0.element.sustained > $1.element.sustained }
        let eligible = ranked.filter { $0.element.active >= minimumActiveFraction }
        let pool = eligible.isEmpty ? Array(ranked.prefix(1)) : eligible
        let best = pool[0].element.sustained
        let chosen = pool.filter { $0.element.sustained >= best - channelSelectionWindowDB }.map(\.offset).sorted()

        var samples: [Float]
        let label: String
        if channelCount == 1 {
            samples = channels[0]
            label = "mono"
        } else if chosen.count == 1 {
            samples = channels[chosen[0]]
            label = "ch\(chosen[0] + 1)"
        } else {
            samples = [Float](repeating: 0, count: frameCount)
            for ch in chosen {
                vDSP_vadd(samples, 1, channels[ch], 1, &samples, 1, vDSP_Length(frameCount))
            }
            var scale = 1 / Float(chosen.count)
            vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(frameCount))
            label = "ch" + chosen.map { String($0 + 1) }.joined(separator: "+")
        }
        var peak: Float = 0
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        return MonoTake(
            samples: samples, channelCount: channelCount, channelLabel: label,
            channelRanking: ranked.prefix(4).map { (channel: $0.offset + 1, sustainedDBFS: $0.element.sustained, activeFraction: $0.element.active) },
            rmsDBFS: dbfs(rms(samples)), peakDBFS: dbfs(peak)
        )
    }

    /// Level normalization with a limiter: one gain brings the take to
    /// `targetRMSDBFS` (capped at `maximumGainDB`), then a peak limiter with
    /// instant attack and `limiterReleaseSeconds` release holds every peak
    /// under `peakCeilingDBFS`. Speech averages 30 dB below its loudest
    /// instant, so a plain gain stopped far short of target whenever a
    /// single peak would have clipped; the limiter only touches those
    /// instants. Quiet takes get louder; already-loud takes are left alone.
    static func normalized(_ take: MonoTake, sampleRate: Double = 16_000) -> MonoTake {
        guard !take.samples.isEmpty, take.rmsDBFS > -120 else { return take }
        let gainDB = max(0, min(maximumGainDB, targetRMSDBFS - take.rmsDBFS))
        var result = take
        if gainDB > 0.1 {
            var gain = powf(10, gainDB / 20)
            vDSP_vsmul(take.samples, 1, &gain, &result.samples, 1, vDSP_Length(take.samples.count))
            result.gainDB = gainDB
        }
        let limited = limit(result.samples, ceilingDBFS: peakCeilingDBFS, sampleRate: sampleRate)
        result.samples = limited.samples
        result.limitedDB = limited.deepestReductionDB
        return result
    }

    /// Saved audio brought to the level live dictation is sent at. Speech
    /// engines are tuned for that level: well below it, a recording full of
    /// words can come back empty. Already-levelled audio passes through.
    static func levelled(_ pcm: Data, sampleRate: Double) -> Data {
        let samples = pcm.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        guard !samples.isEmpty else { return pcm }
        var rms: Float = 0
        var peak: Float = 0
        vDSP_rmsqv(samples, 1, &rms, vDSP_Length(samples.count))
        vDSP_maxmgv(samples, 1, &peak, vDSP_Length(samples.count))
        let take = MonoTake(samples: samples, channelCount: 1, channelLabel: "mono", channelRanking: [],
                            rmsDBFS: dbfs(rms), peakDBFS: dbfs(peak))
        return normalized(take, sampleRate: sampleRate).samples.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Peak limiter: per 1 ms block, the gain needed to keep the block's
    /// peak under `ceiling`; instant attack (the reduction applies to the
    /// block that needs it), exponential release toward unity. A final
    /// clamp guarantees the ceiling regardless.
    static func limit(_ samples: [Float], ceilingDBFS: Float, sampleRate: Double) -> (samples: [Float], deepestReductionDB: Float) {
        guard !samples.isEmpty else { return (samples, 0) }
        let ceiling = powf(10, ceilingDBFS / 20)
        let block = max(1, Int(sampleRate * 0.001))
        let releasePerBlock = Float(exp(-Double(block) / (limiterReleaseSeconds * sampleRate)))
        var output = samples
        var gain: Float = 1
        var deepest: Float = 1
        var index = 0
        while index < samples.count {
            let end = min(index + block, samples.count)
            var peak: Float = 0
            samples.withUnsafeBufferPointer { ptr in
                vDSP_maxmgv(ptr.baseAddress! + index, 1, &peak, vDSP_Length(end - index))
            }
            let needed = peak > ceiling ? ceiling / peak : 1
            gain = min(needed, gain + (1 - gain) * (1 - releasePerBlock))
            deepest = min(deepest, gain)
            if gain < 1 {
                var g = gain
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_vsmul(out.baseAddress! + index, 1, &g, out.baseAddress! + index, 1, vDSP_Length(end - index))
                }
            }
            index = end
        }
        var low = -ceiling, high = ceiling
        vDSP_vclip(output, 1, &low, &high, &output, 1, vDSP_Length(output.count))
        return (output, deepest < 1 ? dbfs(deepest) : 0)
    }

    private static func frameLevelsDBFS(_ samples: [Float], frameLength: Int) -> [Float] {
        guard samples.count >= frameLength else { return samples.isEmpty ? [] : [dbfs(rms(samples))] }
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameLength)
        samples.withUnsafeBufferPointer { ptr in
            var start = 0
            while start + frameLength <= samples.count {
                var value: Float = 0
                vDSP_rmsqv(ptr.baseAddress! + start, 1, &value, vDSP_Length(frameLength))
                levels.append(dbfs(value))
                start += frameLength
            }
        }
        return levels
    }

    private static func rms(_ x: [Float]) -> Float {
        var value: Float = 0
        vDSP_rmsqv(x, 1, &value, vDSP_Length(x.count))
        return value
    }

    private static func dbfs(_ v: Float) -> Float { 20 * log10(max(v, 1e-9)) }

    /// Resamples float32 mono audio to 16 kHz through `AVAudioConverter`,
    /// which low-pass filters before decimating. The previous linear
    /// interpolation had no anti-alias filter, so everything above 8 kHz in
    /// a 44.1/48 kHz capture (consonant energy, hiss) folded down into the
    /// speech band the recogniser listens to.
    static func resampleTo16kHz(_ samples: [Float], from sourceSR: Double) -> Data {
        guard sourceSR != Self.targetSampleRate, !samples.isEmpty else {
            return samples.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceSR, channels: 1, interleaved: false),
              let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return linearResampleTo16kHz(samples, from: sourceSR)
        }
        converter.sampleRateConverterQuality = .max
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            input.floatChannelData?[0].update(from: src.baseAddress!, count: samples.count)
        }
        let ratio = Self.targetSampleRate / sourceSR
        let capacity = AVAudioFrameCount(Double(samples.count) * ratio) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            return linearResampleTo16kHz(samples, from: sourceSR)
        }
        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, conversionError == nil, output.frameLength > 0, let channel = output.floatChannelData else {
            HotkeyService.recordDiagnostics("capture resample: converter failed (\(conversionError?.localizedDescription ?? "status \(status.rawValue)")), linear fallback")
            return linearResampleTo16kHz(samples, from: sourceSR)
        }
        return Data(buffer: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
    }

    /// The old resampler, kept only as a fallback if the converter cannot be built.
    static func linearResampleTo16kHz(_ samples: [Float], from sourceSR: Double) -> Data {
        let ratio = Self.targetSampleRate / sourceSR
        let targetCount = Int(round(Double(samples.count) * ratio))
        guard targetCount > 0, samples.count > 1 else { return Data() }
        var output = [Float](repeating: 0, count: targetCount)
        var control = vDSP.ramp(in: Float(0)...Float(samples.count - 1), count: targetCount)
        vDSP_vlint(samples, &control, 1, &output, 1, vDSP_Length(targetCount), vDSP_Length(samples.count))
        return output.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

struct CapturedAudio {
    let data: Data       // raw little-endian float32 PCM
    let durationSeconds: Double
    let sampleRate: Int  // always 16000
    let frameCount: Int
}

enum AudioCaptureError: Error, LocalizedError {
    case noInputDevice
    case inputDeviceUnavailable(String)
    case cannotSelectInputDevice(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: "No microphone found."
        case .inputDeviceUnavailable:
            "The selected microphone is not connected. Connect it or choose another microphone in Dictator Settings."
        case .cannotSelectInputDevice:
            "Dictator could not activate the selected microphone. Choose another microphone in Dictator Settings."
        }
    }
}
