import AVFoundation
import Accelerate
import XCTest
@testable import Dictator

/// Covers `AudioCaptureService`'s checkpoint path: a delayed/"stale" tap
/// callback must never contaminate a different capture generation's RAM
/// buffers or on-disk checkpoint, and an engine/device restart mid-hold
/// must finalize the pre-restart audio as its own recoverable segment,
/// never silently mislabel it, and never let it be deleted by the session's
/// own outcome cleanup. Every test drives `AudioCaptureService` without
/// ever calling `startEngine()`/touching the real `AVAudioEngine` — engine
/// start/stop is a no-op on an engine that was never started, and
/// `sampleRateOverrideForTesting` stands in for whatever the real device
/// format would be — so these never depend on this test host's actual audio
/// hardware or TCC grants.
final class AudioCaptureServiceTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AudioCaptureServiceTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        tempDirectory = nil
        super.tearDown()
    }

    private func makeStore() -> RecordingCheckpointStore {
        RecordingCheckpointStore(directory: tempDirectory)
    }

    /// A tiny flush interval so a handful of samples flush to disk
    /// immediately instead of sitting in `RecordingCheckpointWriter.pending`
    /// — makes "did this actually get written" assertions deterministic.
    private func makeService(store: RecordingCheckpointStore, sampleRate: Double = 16_000) -> AudioCaptureService {
        let service = AudioCaptureService(checkpointStore: store, checkpointFlushIntervalSeconds: 0.0001)
        service.sampleRateOverrideForTesting = sampleRate
        return service
    }

    private func makeBuffer(sampleRate: Double, frameCount: Int, amplitude: Float = 0.5) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channel = buffer.floatChannelData?[0] {
            for i in 0..<frameCount { channel[i] = amplitude }
        }
        return buffer
    }

    // MARK: - Stale-generation tap callback

    func testFinishHandlingAudioBufferAppendsAFreshGenerationBuffer() {
        let store = makeStore()
        let service = makeService(store: store)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")

        let generation = service.beginHandlingAudioBuffer()
        XCTAssertNotNil(generation)
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 16_000, frameCount: 100), generation: generation!)
        service.drainCheckpointQueueForTesting()

        XCTAssertEqual(service.capturedBufferCountForTesting, 1)
        let take = store.listTakes().first
        XCTAssertEqual(take?.id, "edge-s1")
        XCTAssertGreaterThan(take?.durationSeconds ?? 0, 0, "the buffer should have been flushed to the checkpoint")
    }

    func testFinishHandlingAudioBufferDropsAStaleGenerationBuffer() {
        let store = makeStore()
        let service = makeService(store: store)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")

        // "Observe isCapturing == true, pause" — capture the generation a
        // tap callback for session s1 would have seen.
        let staleGeneration = service.beginHandlingAudioBuffer()
        XCTAssertNotNil(staleGeneration)

        // While that callback is "paused," s1 stops and s2 starts — a new
        // generation, a fresh (empty) `buffers`, and a fresh writer.
        service.stopCapture()
        service.startCapture(sessionId: "s2", edgeName: "MacBook")
        service.drainCheckpointQueueForTesting()

        // The stale callback finally "resumes" and tries to commit s1's
        // buffer using the generation it captured before the pause.
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 16_000, frameCount: 100), generation: staleGeneration!)
        service.drainCheckpointQueueForTesting()

        XCTAssertEqual(service.capturedBufferCountForTesting, 0, "s1's stale buffer must not land in s2's RAM buffers")
        let take = store.listTakes().first(where: { $0.id == "edge-s2" })
        XCTAssertEqual(take?.durationSeconds ?? 0, 0, accuracy: 0.001, "s1's stale buffer must not be written into s2's checkpoint")
    }

    func testBeginHandlingAudioBufferReturnsNilWhenNotCapturing() {
        let store = makeStore()
        let service = makeService(store: store)

        XCTAssertNil(service.beginHandlingAudioBuffer())
    }

    // MARK: - Engine/device restart mid-hold

    func testEngineRestartInterruptsTheSegmentAndGivesItItsOwnTakeId() {
        let store = makeStore()
        let service = makeService(store: store, sampleRate: 48_000)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")
        let generation = service.beginHandlingAudioBuffer()!
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 48_000, frameCount: 200), generation: generation)
        service.drainCheckpointQueueForTesting()
        XCTAssertEqual(store.listTakes().map(\.id), ["edge-s1"])

        // Engine/device restart mid-hold. `preserveCapture: true` mirrors
        // what `startEngine` does internally before reconfiguring — the
        // engine itself was never started in this test, so tearing it down
        // is a harmless no-op; only the checkpoint-segment behavior matters
        // here.
        service.stopEngine(preserveCapture: true)
        service.drainCheckpointQueueForTesting()

        let takes = store.listTakes()
        XCTAssertEqual(takes.map(\.id), ["edge-s1-seg1"], "the plain edgeTakeId must no longer point at the interrupted segment")
        XCTAssertEqual(takes.first?.metadata.status, .interrupted)
        XCTAssertEqual(takes.first?.metadata.sampleRate, 48_000, "the interrupted segment keeps ITS OWN (pre-restart) rate")
    }

    func testFailedRestartLeavesTheInterruptedSegmentRecoverableAndDoesNotDeleteItOnNoAudioCleanup() {
        let store = makeStore()
        let service = makeService(store: store, sampleRate: 48_000)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")
        let generation = service.beginHandlingAudioBuffer()!
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 48_000, frameCount: 200), generation: generation)
        service.drainCheckpointQueueForTesting()

        service.stopEngine(preserveCapture: true)
        service.drainCheckpointQueueForTesting()
        // The restart fails here (no device / permission lost) — production
        // code simply never reaches `resumeCheckpointSegmentIfNeeded()` in
        // that case, so this test doesn't call it either.

        // `stopCapture()` sees empty RAM buffers (cleared by `stopEngine`)
        // and returns nil — mirroring the broker's `.cancelled(.noAudio)`
        // path, which deletes `edgeTakeId(sessionId)`.
        let captured = service.stopCapture()
        XCTAssertNil(captured)
        store.delete(RecordingCheckpointStore.edgeTakeId("s1")) // what EdgeRuntime's cleanup would do

        let takes = store.listTakes()
        XCTAssertEqual(takes.map(\.id), ["edge-s1-seg1"], "the interrupted segment survives a .noAudio cleanup of the plain take id")
        XCTAssertEqual(takes.first?.metadata.status, .interrupted)
    }

    func testSuccessfulRestartResumesCheckpointingAtTheNewRateUnderThePlainTakeId() {
        let store = makeStore()
        let service = makeService(store: store, sampleRate: 48_000)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")
        let firstGeneration = service.beginHandlingAudioBuffer()!
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 48_000, frameCount: 200), generation: firstGeneration)
        service.drainCheckpointQueueForTesting()

        service.stopEngine(preserveCapture: true)
        service.drainCheckpointQueueForTesting()

        // The restart succeeds at a different sample rate.
        service.sampleRateOverrideForTesting = 44_100
        service.resumeCheckpointSegmentIfNeeded()
        service.drainCheckpointQueueForTesting()

        let secondGeneration = service.beginHandlingAudioBuffer()!
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 44_100, frameCount: 200), generation: secondGeneration)
        service.drainCheckpointQueueForTesting()

        let takes = store.listTakes().sorted { $0.id < $1.id }
        XCTAssertEqual(takes.map(\.id), ["edge-s1", "edge-s1-seg1"])
        let interrupted = takes.first { $0.id == "edge-s1-seg1" }
        let resumed = takes.first { $0.id == "edge-s1" }
        XCTAssertEqual(interrupted?.metadata.status, .interrupted)
        XCTAssertEqual(interrupted?.metadata.sampleRate, 48_000)
        XCTAssertEqual(resumed?.metadata.status, .recording)
        XCTAssertEqual(resumed?.metadata.sampleRate, 44_100, "the resumed segment is labeled at the NEW device rate")
    }

    // MARK: - deleteCheckpoint is serialized behind a pending finish()

    func testDeleteCheckpointRunsAfterAPendingFinishOnTheSameQueue() {
        let store = makeStore()
        let service = makeService(store: store)
        service.startCapture(sessionId: "s1", edgeName: "MacBook")
        let generation = service.beginHandlingAudioBuffer()!
        service.finishHandlingAudioBuffer(makeBuffer(sampleRate: 16_000, frameCount: 100), generation: generation)

        // `stopCapture()` enqueues `finish()` on the checkpoint queue; a
        // cleanup call racing in right behind it (this is what
        // `EdgeRuntime.applyCheckpointCleanup` does via
        // `deleteCheckpoint(takeId:)`) must be queued behind that `finish()`
        // rather than running directly on the caller's thread/actor — else
        // a delete that "won" the race would be resurrected by the
        // still-in-flight `finish()`'s own status write.
        _ = service.stopCapture()
        service.deleteCheckpoint(takeId: "edge-s1")
        service.drainCheckpointQueueForTesting()

        XCTAssertTrue(store.listTakes().isEmpty, "the delete must win regardless of the finish() race, never be undone by it")
    }

    func testResumeCheckpointSegmentDoesNothingWhenNotCapturing() {
        let store = makeStore()
        let service = makeService(store: store)

        service.resumeCheckpointSegmentIfNeeded()
        service.drainCheckpointQueueForTesting()

        XCTAssertTrue(store.listTakes().isEmpty)
    }

    // MARK: - Mono selection and resampling

    private func makeBuffer(sampleRate: Double, channels: [[Float]]) -> AVAudioPCMBuffer {
        // More than two channels needs an explicit (discrete) layout, like a
        // real multi-input interface presents.
        let format: AVAudioFormat
        if channels.count <= 2 {
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: AVAudioChannelCount(channels.count), interleaved: false)!
        } else {
            let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels.count))!
            format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, interleaved: false, channelLayout: layout)
        }
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = AVAudioFrameCount(channels[0].count)
        for (index, channel) in channels.enumerated() {
            channel.withUnsafeBufferPointer { buffer.floatChannelData![index].update(from: $0.baseAddress!, count: channel.count) }
        }
        return buffer
    }

    private func tone(_ hz: Double, amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// Speech-like test signal: a tone that is on for 60% of the time in
    /// 200 ms bursts, silent otherwise — sustained across the take.
    private func speechLike(amplitude: Float, seconds: Double, sampleRate: Double) -> [Float] {
        let burst = Int(0.2 * sampleRate), gap = Int(0.13 * sampleRate)
        var out: [Float] = []
        var t = 0
        while out.count < Int(seconds * sampleRate) {
            for _ in 0..<burst { out.append(amplitude * Float(sin(2 * Double.pi * 300 * Double(t) / sampleRate))); t += 1 }
            out.append(contentsOf: [Float](repeating: 0, count: gap)); t += gap
        }
        return Array(out.prefix(Int(seconds * sampleRate)))
    }

    /// The saved copy keeps the microphone's level on any interface, however
    /// many of its channels are empty.
    func testACheckpointIsNotDividedByTheChannelCount() {
        for channelCount in [1, 2, 20, 64] {
            var channels = [[Float]](repeating: [Float](repeating: 0, count: 256), count: channelCount)
            channels[channelCount - 1] = [Float](repeating: 0.2, count: 256)
            let samples = AudioCaptureService.checkpointSamples(makeBuffer(sampleRate: 44_100, channels: channels))
            XCTAssertEqual(samples.count, 256)
            XCTAssertEqual(samples[100], 0.2, accuracy: 0.0001, "\(channelCount) channels")
        }
    }

    func testMonoTakePicksTheDominantChannelOfAnInterface() throws {
        let mic = speechLike(amplitude: 0.3, seconds: 1, sampleRate: 48_000)
        let silent = [Float](repeating: 0.001, count: mic.count)
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 48_000, channels: [silent, mic])]))
        XCTAssertEqual(take.channelCount, 2)
        XCTAssertEqual(take.channelLabel, "ch2")
        XCTAssertEqual(take.samples.count, mic.count)
        XCTAssertEqual(take.samples[100], mic[100], accuracy: 1e-6, "the microphone channel is used at full level, not halved")
        XCTAssertEqual(take.channelRanking.first?.channel, 2)
        XCTAssertGreaterThan(take.channelRanking.first!.activeFraction, 0.5)
    }

    /// The Scarlett case: twenty channels, the mic on one, a mirrored copy
    /// on another, eighteen carrying nothing. The old average lost 26 dB.
    func testMonoTakeOnATwentyChannelInterfaceKeepsOnlyTheMicChannels() throws {
        let mic = speechLike(amplitude: 0.3, seconds: 1, sampleRate: 44_100)
        let mirror = speechLike(amplitude: 0.2, seconds: 1, sampleRate: 44_100) // within 6 dB
        var channels = [[Float]](repeating: [Float](repeating: 0.0005, count: mic.count), count: 20)
        channels[2] = mic
        channels[7] = mirror
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 44_100, channels: channels)]))
        XCTAssertEqual(take.channelCount, 20)
        XCTAssertEqual(take.channelLabel, "ch3+8")
        XCTAssertEqual(take.channelRanking.map(\.channel).prefix(2), [3, 8])
        XCTAssertEqual(take.samples[100], (mic[100] + mirror[100]) / 2, accuracy: 1e-6)
    }

    /// The failure of 21 September: the interface's loopback pair recorded
    /// the app's own 50 ms start beep at high level and digital silence
    /// otherwise, out-ranking the real mic on plain RMS. A beep is not
    /// sustained signal; the mic must win.
    func testMonoTakeIgnoresALoopbackPairThatOnlyCarriesABeep() throws {
        let sampleRate = 44_100.0
        let mic = speechLike(amplitude: 0.02, seconds: 2, sampleRate: sampleRate) // quiet mic, about -37 dBFS
        var beep = [Float](repeating: 0, count: mic.count)
        for i in 0..<Int(0.05 * sampleRate) { beep[i] = 0.9 * Float(sin(2 * Double.pi * 700 * Double(i) / sampleRate)) }
        var channels = [[Float]](repeating: [Float](repeating: 0, count: mic.count), count: 20)
        channels[0] = mic
        channels[10] = beep
        channels[11] = beep
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: sampleRate, channels: channels)]))
        XCTAssertEqual(take.channelLabel, "ch1")
        XCTAssertEqual(take.samples[1_000], mic[1_000], accuracy: 1e-6)
        XCTAssertEqual(take.channelRanking.first?.channel, 1, "the mic ranks first on sustained level")
        XCTAssertGreaterThan(take.channelRanking.first!.activeFraction, 0.5)
    }

    func testNormalizationLiftsAQuietTakeButNeverASilentOrLoudOne() throws {
        let quiet = tone(300, amplitude: 0.003, seconds: 0.3, sampleRate: 16_000) // about -53 dBFS RMS
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 16_000, channels: [quiet])]))
        let lifted = AudioCaptureService.normalized(take)
        XCTAssertEqual(lifted.gainDB, 33.5, accuracy: 0.5)
        var rms: Float = 0
        vDSP_rmsqv(lifted.samples, 1, &rms, vDSP_Length(lifted.samples.count))
        XCTAssertEqual(20 * log10(rms), AudioCaptureService.targetRMSDBFS, accuracy: 0.5)
        XCTAssertEqual(lifted.limitedDB, 0, "a sine at -20 dBFS never reaches the ceiling")

        let veryQuiet = tone(300, amplitude: 0.00005, seconds: 0.3, sampleRate: 16_000) // about -89 dBFS
        let capped = AudioCaptureService.normalized(try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 16_000, channels: [veryQuiet])])))
        XCTAssertEqual(capped.gainDB, AudioCaptureService.maximumGainDB, accuracy: 0.01, "gain is capped, hiss is not amplified to full scale")

        let loud = tone(300, amplitude: 0.5, seconds: 0.3, sampleRate: 16_000)
        let untouched = AudioCaptureService.normalized(try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 16_000, channels: [loud])])))
        XCTAssertEqual(untouched.gainDB, 0)
        XCTAssertEqual(untouched.samples[10], loud[10])

        let silent = [Float](repeating: 0, count: 4_800)
        let stillSilent = AudioCaptureService.normalized(try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 16_000, channels: [silent])])))
        XCTAssertEqual(stillSilent.gainDB, 0)
    }

    /// Quiet speech with one loud spike: the take must still reach the
    /// target level (the spike alone is limited) and the spike must sit at
    /// the ceiling, not above it.
    func testLimiterLetsAQuietSpikyTakeReachTargetLevel() throws {
        var spiky = speechLike(amplitude: 0.01, seconds: 1, sampleRate: 16_000)
        spiky[5_000] = 0.5
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [makeBuffer(sampleRate: 16_000, channels: [spiky])]))
        let lifted = AudioCaptureService.normalized(take)
        XCTAssertGreaterThan(lifted.gainDB, 20, "the spike no longer caps the gain")
        var peak: Float = 0
        vDSP_maxmgv(lifted.samples, 1, &peak, vDSP_Length(lifted.samples.count))
        XCTAssertLessThanOrEqual(20 * log10(peak), AudioCaptureService.peakCeilingDBFS + 0.05)
        XCTAssertLessThan(lifted.limitedDB, -10, "the spike was pulled down")
        // Speech away from the spike is untouched by the limiter: pure gain.
        let expectedGain = powf(10, lifted.gainDB / 20)
        XCTAssertEqual(lifted.samples[10_000], spiky[10_000] * expectedGain, accuracy: 1e-4)
    }

    func testMonoTakeConcatenatesBuffersAndReturnsNilForNothing() throws {
        let a = makeBuffer(sampleRate: 16_000, channels: [[0.1, 0.2]])
        let b = makeBuffer(sampleRate: 16_000, channels: [[0.3]])
        let take = try XCTUnwrap(AudioCaptureService.monoTake(from: [a, b]))
        XCTAssertEqual(take.samples, [0.1, 0.2, 0.3])
        XCTAssertEqual(take.channelLabel, "mono")
        XCTAssertNil(AudioCaptureService.monoTake(from: []))
    }

    /// Anti-aliasing: a 12 kHz tone captured at 48 kHz lies above the 8 kHz
    /// Nyquist limit of the 16 kHz output. A proper resampler removes it;
    /// the old linear interpolation folded it down to 4 kHz.
    func testResamplerRemovesEnergyAboveNyquist() {
        let sampleRate = 48_000.0
        let above = tone(12_000, amplitude: 0.5, seconds: 1, sampleRate: sampleRate)
        let data = AudioCaptureService.resampleTo16kHz(above, from: sampleRate)
        let output = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(output.count, 16_000, accuracy: 64)
        var rms: Float = 0
        vDSP_rmsqv(Array(output.dropFirst(1_000)), 1, &rms, vDSP_Length(output.count - 1_000))
        XCTAssertLessThan(20 * log10(max(rms, 1e-9)), -40, "a 12 kHz tone must not survive decimation to 16 kHz")

        let speechBand = tone(1_000, amplitude: 0.5, seconds: 1, sampleRate: sampleRate)
        let kept = AudioCaptureService.resampleTo16kHz(speechBand, from: sampleRate).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        var keptRMS: Float = 0
        vDSP_rmsqv(Array(kept.dropFirst(1_000)), 1, &keptRMS, vDSP_Length(kept.count - 1_000))
        XCTAssertEqual(20 * log10(keptRMS), 20 * log10(0.5 / sqrt(2)), accuracy: 0.5, "a 1 kHz tone passes at the same level")
    }

    func testResamplerPassesThrough16k() {
        let samples: [Float] = [0.1, -0.2, 0.3]
        let data = AudioCaptureService.resampleTo16kHz(samples, from: 16_000)
        XCTAssertEqual(data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }, samples)
    }
}
