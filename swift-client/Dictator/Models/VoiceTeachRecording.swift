import Foundation

/// Decides when a Teach take ends: two seconds of quiet after the person
/// spoke, or six seconds in all. Pure, so it can be tested with made-up levels.
struct VoiceTeachEndpointer: Equatable {
    var speechLevel: Float = 0.05
    var silenceSeconds: TimeInterval = 2.0
    var maxSeconds: TimeInterval = 6.0
    /// A pause shorter than this is just breathing between words: no
    /// countdown is shown for it.
    var countdownAfter: TimeInterval = 0.5

    private var start: TimeInterval?
    private var lastVoice: TimeInterval?
    private var now: TimeInterval?

    /// True when the take should stop. `time` is any steadily increasing clock.
    mutating func feed(level: Float, at time: TimeInterval) -> Bool {
        let began = start ?? time
        start = began
        now = time
        if level >= speechLevel { lastVoice = time }
        if time - began >= maxSeconds { return true }
        if let lastVoice, time - lastVoice >= silenceSeconds { return true }
        return false
    }

    /// How far the quiet has run toward stopping the take, 0 to 1, once it
    /// has lasted `countdownAfter`; nil while speaking, before anyone has
    /// spoken, or for a short pause. Resets when speech resumes.
    var silenceProgress: Double? {
        guard let lastVoice, let now, now - lastVoice >= countdownAfter else { return nil }
        return min(1, max(0, (now - lastVoice) / silenceSeconds))
    }

    /// Time left before the overall limit ends the take.
    var secondsLeft: TimeInterval {
        guard let start, let now else { return maxSeconds }
        return max(0, maxSeconds - (now - start))
    }
}
