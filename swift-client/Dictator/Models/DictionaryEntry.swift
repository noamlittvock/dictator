import Foundation
import SwiftData

@Model
final class DictionaryEntry {
    var id: UUID
    var pattern: String
    var replacement: String
    var isVocabulary: Bool

    // Defaults are on the stored properties for unversioned lightweight migration.
    var isStarred: Bool = false
    var useCount: Int = 0
    var lastUsedAt: Date? = nil
    var origin: String? = nil
    var isForgotten: Bool = false

    init(pattern: String, replacement: String, isVocabulary: Bool = true) {
        self.id = UUID()
        self.pattern = pattern
        self.replacement = replacement
        self.isVocabulary = isVocabulary
    }
}
