import Foundation
import Observation

/// What a Teach take needs from this Mac's microphone. `EdgeRuntime` is it.
@MainActor
protocol VoiceTeachRecording: AnyObject {
    var teachLevelObserver: ((Float) -> Void)? { get set }
    func beginTeachRecording() -> Bool
    func endTeachRecording() -> CapturedAudio?
    func cancelTeachRecording()
}

extension EdgeRuntime: VoiceTeachRecording {}

/// Where the Teach sheet finds the microphone and the speech path. The app
/// fills these in; tests fill in a fake.
@MainActor
final class VoiceTeachService {
    static let shared = VoiceTeachService()

    var recorder: VoiceTeachRecording?
    /// The words in a recording as spoken, from the main Mac's speech path.
    var transcribe: ((CapturedAudio) async throws -> String)?
}

/// The takes of one Teach sheet. The microphone is used only while a take
/// is recording, and only because the person pressed Record.
@MainActor
@Observable
final class VoiceTeachSession {
    enum Phase: Equatable { case ready, recording, transcribing }

    private(set) var phase: Phase = .ready {
        didSet { if phase != oldValue { onPhase?(phase) } }
    }
    /// What each finished take heard, in order. Empty text means silence.
    private(set) var transcripts: [String] = []
    private(set) var message: String?
    private(set) var level: Float = 0
    /// While a take is recording and the person has gone quiet: how far the
    /// quiet has run toward ending the take (0 to 1). Nil otherwise.
    private(set) var silenceProgress: Double?
    /// Whole seconds left before the time limit ends the take.
    private(set) var secondsLeft: Int = 0

    @ObservationIgnored private let service: VoiceTeachService
    @ObservationIgnored private var finishRecording: (() -> Void)?
    @ObservationIgnored private var cancelled = false
    /// Injected so tests need no clock.
    @ObservationIgnored var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    @ObservationIgnored var endpointer = VoiceTeachEndpointer()
    /// Told when the take changes phase (Dictate in Shortcuts draws the
    /// badge from it).
    @ObservationIgnored var onPhase: ((Phase) -> Void)?
    /// Told with each mic level while recording: the level, how far the quiet
    /// has run toward ending the take (nil while speaking), and the whole
    /// seconds left before the time limit.
    @ObservationIgnored var onTick: ((Float, Double?, Int) -> Void)?
    /// How long the last recording was, in seconds.
    private(set) var lastAudioSeconds: Double = 0

    /// How many takes make a full set: four for Teach, two for Check name.
    let takeCount: Int

    init(service: VoiceTeachService = .shared, takeCount: Int = VoiceTeach.takeCount) {
        self.service = service
        self.takeCount = takeCount
    }

    var isComplete: Bool { transcripts.count >= takeCount }

    func reset() {
        guard phase == .ready else { return }
        transcripts = []
        message = nil
    }

    /// Stops a take that is recording now (the person clicked again).
    func stopNow() { finishRecording?() }

    /// Leaves the sheet: ends any take without keeping anything.
    func cancel() {
        cancelled = true
        if phase == .recording { finishRecording?() }
    }

    /// Records one take, then turns it into words. Returns when done.
    func record() async {
        guard phase == .ready, !isComplete else { return }
        guard let recorder = service.recorder, service.transcribe != nil else {
            message = "Recording isn’t available right now."
            return
        }
        message = nil
        cancelled = false
        guard recorder.beginTeachRecording() else {
            message = "Another recording is in progress. Finish it and try again."
            return
        }
        phase = .recording
        var endpointer = self.endpointer
        silenceProgress = nil
        secondsLeft = Int(endpointer.maxSeconds.rounded(.up))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            let finish: () -> Void = { [weak self] in
                guard !finished else { return }
                finished = true
                recorder.teachLevelObserver = nil
                self?.finishRecording = nil
                continuation.resume()
            }
            finishRecording = finish
            recorder.teachLevelObserver = { [weak self] level in
                guard let self else { return }
                self.level = level
                let stop = endpointer.feed(level: level, at: self.clock())
                let progress = endpointer.silenceProgress
                // One soft tick when the stop countdown begins.
                if progress != nil, self.silenceProgress == nil { SoundService.playTick() }
                self.silenceProgress = progress
                self.secondsLeft = Int(endpointer.secondsLeft.rounded(.up))
                self.onTick?(level, progress, self.secondsLeft)
                if stop { finish() }
            }
            // Levels only arrive while the mic delivers audio; this makes the
            // limit certain either way.
            let cap = endpointer.maxSeconds + 0.5
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(cap))
                finish()
            }
        }
        level = 0
        silenceProgress = nil
        secondsLeft = 0
        if cancelled {
            recorder.cancelTeachRecording()
            phase = .ready
            return
        }
        guard let audio = recorder.endTeachRecording() else {
            phase = .ready
            message = "Dictator didn’t hear anything. Check your microphone and try again."
            return
        }
        lastAudioSeconds = audio.durationSeconds
        phase = .transcribing
        do {
            let text = try await service.transcribe?(audio) ?? ""
            transcripts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            message = error.localizedDescription
        }
        phase = .ready
    }
}
