import AppKit

/// System sound feedback.
/// Tink (press), Pop (paste ok), Funk (error).
enum SoundService {
    static func playStart() { play("Tink") }
    static func playSuccess() { play("Pop") }
    static func playError() { play("Funk") }

    /// A quiet tick for the "recording is about to end" countdown.
    /// There is no sounds on/off setting, so this always plays.
    static func playTick() { play("Tink", volume: 0.25) }

    /// Hosted unit tests make no sound: an unresponsive audio output would
    /// otherwise stall the main thread inside `NSSound.play`.
    private static let underTest = NSClassFromString("XCTestCase") != nil

    private static func play(_ name: String, volume: Float = 1) {
        guard !underTest, let sound = NSSound(named: name) else { return }
        sound.volume = volume
        sound.play()
    }
}
