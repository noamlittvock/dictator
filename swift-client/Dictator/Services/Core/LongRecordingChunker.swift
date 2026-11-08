import Foundation

/// Splits audio long enough that the inference server would reject it
/// (`MAX_DURATION_S = 120` in `server/server.py`) into sequential windows of
/// at most `maxChunkSeconds`, cutting each boundary at the lowest-energy
/// point within the last `searchWindowSeconds` of the window — a pause
/// between words/sentences rather than mid-syllable — so `DurableTranscriber`
/// can transcribe the pieces separately and join the text with a space
/// instead of losing the whole take to a 413.
///
/// Pure index math: RMS energy is supplied by the caller (`rms`) so this
/// type never touches `Data`/`Float` storage directly, which is what makes
/// it trivial to unit-test against synthetic audio.
enum LongRecordingChunker {
    /// A chunk's frame range, `[startFrame, endFrame)`.
    struct Bounds: Equatable {
        let startFrame: Int
        let endFrame: Int
    }

    /// - Parameters:
    ///   - totalFrames: total sample count of the take.
    ///   - sampleRate: frames per second (16 kHz for everything this ships
    ///     against today, but not assumed).
    ///   - maxChunkSeconds: the longest a single chunk may run.
    ///   - searchWindowSeconds: how far back from each ideal boundary to look
    ///     for a quieter cut point.
    ///   - analysisFrameMs: width of the sliding window used while searching
    ///     for the quietest point.
    ///   - rms: RMS energy of samples `[range.lowerBound, range.upperBound)`.
    static func chunkBounds(
        totalFrames: Int,
        sampleRate: Int,
        maxChunkSeconds: Double = 100,
        searchWindowSeconds: Double = 10,
        analysisFrameMs: Double = 20,
        rms: (Range<Int>) -> Float
    ) -> [Bounds] {
        guard totalFrames > 0, sampleRate > 0 else { return [] }
        let maxChunkFrames = Int(maxChunkSeconds * Double(sampleRate))
        guard maxChunkFrames > 0, totalFrames > maxChunkFrames else {
            return [Bounds(startFrame: 0, endFrame: totalFrames)]
        }
        let searchWindowFrames = max(1, Int(searchWindowSeconds * Double(sampleRate)))
        let analysisFrame = max(1, Int(analysisFrameMs / 1000 * Double(sampleRate)))

        var bounds: [Bounds] = []
        var start = 0
        while start < totalFrames {
            let idealEnd = min(start + maxChunkFrames, totalFrames)
            guard idealEnd < totalFrames else {
                bounds.append(Bounds(startFrame: start, endFrame: totalFrames))
                break
            }
            let searchStart = max(start, idealEnd - searchWindowFrames)
            let cut = lowestEnergyCut(from: searchStart, to: idealEnd, analysisFrame: analysisFrame, rms: rms)
            // A degenerate search range (searchStart == idealEnd, or a cut
            // that didn't move past `start`) would spin forever — always
            // make forward progress.
            let end = cut > start ? cut : idealEnd
            bounds.append(Bounds(startFrame: start, endFrame: end))
            start = end
        }
        return bounds
    }

    /// Slides an `analysisFrame`-wide window across `[from, to)` and returns
    /// the end of whichever window had the lowest RMS — biased toward the
    /// end of a pause (where the next chunk should pick up) rather than its
    /// start.
    private static func lowestEnergyCut(from: Int, to: Int, analysisFrame: Int, rms: (Range<Int>) -> Float) -> Int {
        guard to > from else { return to }
        var bestEnd = to
        var bestEnergy = Float.greatestFiniteMagnitude
        var cursor = from
        while cursor < to {
            let end = min(cursor + analysisFrame, to)
            let energy = rms(cursor..<end)
            if energy < bestEnergy {
                bestEnergy = energy
                bestEnd = end
            }
            cursor = end
        }
        return bestEnd
    }
}
