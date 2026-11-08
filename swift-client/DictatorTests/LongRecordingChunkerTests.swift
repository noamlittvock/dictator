import XCTest
@testable import Dictator

/// Covers `LongRecordingChunker` against synthetic audio: an `rms` closure
/// backed by a plain `[Float]` array standing in for real speech/silence,
/// with no `Data`, file, or network involved.
final class LongRecordingChunkerTests: XCTestCase {
    private let sampleRate = 16_000

    /// `loud` everywhere except a short quiet dip centered at `quietAt`
    /// seconds — a synthetic "pause between sentences."
    private func makeSamples(totalSeconds: Double, quietAt: Double?, quietWidth: Double = 0.3) -> [Float] {
        let total = Int(totalSeconds * Double(sampleRate))
        var samples = [Float](repeating: 0.8, count: total)
        if let quietAt {
            let center = Int(quietAt * Double(sampleRate))
            let half = Int(quietWidth / 2 * Double(sampleRate))
            for i in max(0, center - half)..<min(total, center + half) {
                samples[i] = 0.001
            }
        }
        return samples
    }

    private func rms(_ samples: [Float], _ range: Range<Int>) -> Float {
        guard !range.isEmpty else { return 0 }
        var sum: Double = 0
        for i in range { sum += Double(samples[i]) * Double(samples[i]) }
        return Float((sum / Double(range.count)).squareRoot())
    }

    // MARK: - Short audio: no split

    func testAudioUnderMaxChunkSecondsIsNotSplit() {
        let samples = makeSamples(totalSeconds: 50, quietAt: nil)
        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: samples.count, sampleRate: sampleRate, maxChunkSeconds: 100,
            rms: { rms(samples, $0) }
        )
        XCTAssertEqual(bounds, [.init(startFrame: 0, endFrame: samples.count)])
    }

    func testZeroOrNegativeInputsProduceNoBounds() {
        XCTAssertEqual(LongRecordingChunker.chunkBounds(totalFrames: 0, sampleRate: sampleRate, rms: { _ in 0 }), [])
    }

    // MARK: - Long audio: split at the quiet point

    func testLongAudioCutsAtTheQuietPointNearTheIdealBoundary() {
        // 130s total, max chunk 100s, search window 10s → the chunker looks
        // for the quietest point inside [90s, 100s). Put the pause at 95s so
        // it's unambiguously inside that window.
        let samples = makeSamples(totalSeconds: 130, quietAt: 95)
        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: samples.count, sampleRate: sampleRate, maxChunkSeconds: 100, searchWindowSeconds: 10,
            rms: { rms(samples, $0) }
        )

        XCTAssertEqual(bounds.count, 2)
        XCTAssertEqual(bounds[0].startFrame, 0)
        let cutSeconds = Double(bounds[0].endFrame) / Double(sampleRate)
        XCTAssertEqual(cutSeconds, 95, accuracy: 0.5)
        XCTAssertEqual(bounds[1].startFrame, bounds[0].endFrame)
        XCTAssertEqual(bounds[1].endFrame, samples.count)
    }

    func testChunksNeverExceedMaxChunkSecondsWhenNoQuietPointExists() {
        // No pause at all — the chunker still must not exceed maxChunkSeconds
        // per piece and must always make forward progress.
        let samples = makeSamples(totalSeconds: 250, quietAt: nil)
        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: samples.count, sampleRate: sampleRate, maxChunkSeconds: 100, searchWindowSeconds: 10,
            rms: { rms(samples, $0) }
        )

        XCTAssertFalse(bounds.isEmpty)
        for bound in bounds {
            let seconds = Double(bound.endFrame - bound.startFrame) / Double(sampleRate)
            XCTAssertLessThanOrEqual(seconds, 100.01)
        }
    }

    func testBoundsAreContiguousAndCoverTheWholeTake() {
        let samples = makeSamples(totalSeconds: 305, quietAt: nil)
        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: samples.count, sampleRate: sampleRate, maxChunkSeconds: 100, searchWindowSeconds: 10,
            rms: { rms(samples, $0) }
        )

        XCTAssertEqual(bounds.first?.startFrame, 0)
        XCTAssertEqual(bounds.last?.endFrame, samples.count)
        for (a, b) in zip(bounds, bounds.dropFirst()) {
            XCTAssertEqual(a.endFrame, b.startFrame)
        }
    }

    func testMultipleQuietPointsPicksTheQuietestOneInWindow() {
        // Two dips inside the search window for the first cut: a shallower
        // one and a much quieter one. The chunker should prefer the quieter.
        var samples = makeSamples(totalSeconds: 130, quietAt: nil)
        let sr = Double(sampleRate)
        // Shallow dip at 92s.
        for i in Int(91.9 * sr)..<Int(92.1 * sr) { samples[i] = 0.3 }
        // Much quieter dip at 96s.
        for i in Int(95.9 * sr)..<Int(96.1 * sr) { samples[i] = 0.001 }

        let bounds = LongRecordingChunker.chunkBounds(
            totalFrames: samples.count, sampleRate: sampleRate, maxChunkSeconds: 100, searchWindowSeconds: 10,
            rms: { rms(samples, $0) }
        )
        let cutSeconds = Double(bounds[0].endFrame) / sr
        XCTAssertEqual(cutSeconds, 96, accuracy: 0.5)
    }
}
