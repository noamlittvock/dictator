import Foundation
import SwiftData

@Model
final class DictationStats {
    var totalWords: Int
    var totalDictations: Int
    var totalAudioSeconds: Double

    init() {
        self.totalWords = 0
        self.totalDictations = 0
        self.totalAudioSeconds = 0
    }

    func record(wordCount: Int, durationSeconds: Double) {
        // Rows already stored were never bounded; a total must not crash the app.
        let (words, overflow) = totalWords.addingReportingOverflow(wordCount)
        totalWords = overflow ? Int.max : words
        totalDictations += 1
        totalAudioSeconds += durationSeconds
    }
}
