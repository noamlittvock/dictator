import Foundation
import CoreServices

struct VocabularyPack: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var summary: String
    var language: String
    var terms: [String]
    var apps: [String]
    var alwaysOn: Bool?
}

enum VocabularyPackCatalog {
    static var all: [VocabularyPack] { bundled }

    private static let bundled: [VocabularyPack] = {
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("vocabulary-packs") else { return [] }
        return (try? load(from: folder)) ?? []
    }()

    /// Strict loader shared by the bundle and synthetic fixture tests. Only the
    /// top-level JSON files are packs; metadata and candidates are not loaded.
    static func load(from folder: URL) throws -> [VocabularyPack] {
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        var packs: [VocabularyPack] = []
        var seen = Set<String>()
        for file in files {
            let pack = try JSONDecoder().decode(VocabularyPack.self, from: Data(contentsOf: file))
            guard validID(pack.id), file.deletingPathExtension().lastPathComponent == pack.id,
                  !pack.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !pack.language.isEmpty,
                  pack.terms.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 200 }),
                  Set(pack.terms.map { $0.lowercased() }).count == pack.terms.count,
                  Set(pack.apps).count == pack.apps.count,
                  pack.apps.allSatisfy({ $0.contains(".") && !$0.contains(" ") }),
                  seen.insert(pack.id).inserted else {
                throw CocoaError(.fileReadCorruptFile)
            }
            packs.append(pack)
        }
        // Catalog display order; recognition assigns priority when selecting.
        return packs.filter { $0.alwaysOn == true } + packs.filter { $0.alwaysOn != true }
    }

    static func automaticIDs(installedBundleIDs: Set<String>) -> [String] {
        automaticIDs(in: all, installedBundleIDs: installedBundleIDs)
    }

    static func automaticIDs(in packs: [VocabularyPack], installedBundleIDs: Set<String>) -> [String] {
        packs.filter { pack in pack.apps.contains { installedBundleIDs.contains($0) } }.map(\.id)
    }

    static func activeTerms(automatic: Bool, on: [String], off: [String], installedBundleIDs: Set<String>,
                            destinationBundleID: String?, languages: [String]) -> [String] {
        activeTerms(in: all, automatic: automatic, on: on, off: off, installedBundleIDs: installedBundleIDs,
                    destinationBundleID: destinationBundleID, languages: languages)
    }

    /// Pure selection overload allows tests to supply packs without reading apps
    /// or settings. Unknown IDs survive in settings for newer/language catalogs.
    static func activeTerms(in packs: [VocabularyPack], automatic: Bool, on: [String], off: [String],
                            installedBundleIDs: Set<String>, destinationBundleID: String?, languages: [String]) -> [String] {
        let enabled = Set(on)
        let disabled = Set(off)
        let personLanguages = Set(languages.map(languageBase))
        // A destination on another Mac may not be installed on the main Mac.
        let availableApps = installedBundleIDs.union(destinationBundleID.map { [$0] } ?? [])
        let automatic = automatic ? Set(automaticIDs(in: packs, installedBundleIDs: availableApps)) : []
        let active = packs.filter {
            !disabled.contains($0.id) && personLanguages.contains(languageBase($0.language)) &&
            ($0.alwaysOn == true || enabled.contains($0.id) || automatic.contains($0.id))
        }
        let matchesDestination: (VocabularyPack) -> Bool = { pack in
            destinationBundleID.map { pack.apps.contains($0) } ?? false
        }
        func priority(_ pack: VocabularyPack) -> Int {
            if matchesDestination(pack) { return 0 }
            if pack.alwaysOn == true { return 3 }
            return enabled.contains(pack.id) ? 1 : 2
        }
        let ordered = active.enumerated().sorted {
            let lhs = priority($0.element), rhs = priority($1.element)
            return lhs == rhs ? $0.offset < $1.offset : lhs < rhs
        }.map(\.element)
        // Share the finite prompt across fields instead of exhausting it on
        // the first pack. Destination fields get two words per round. Consume
        // duplicates without spending a turn, retaining each pack's order.
        var cursors = Array(repeating: 0, count: ordered.count)
        var seen = Set<String>()
        var terms: [String] = []
        while ordered.indices.contains(where: { cursors[$0] < ordered[$0].terms.count }) {
            for index in ordered.indices {
                let pack = ordered[index]
                for _ in 0..<(matchesDestination(pack) ? 2 : 1) {
                    while cursors[index] < pack.terms.count {
                        let term = pack.terms[cursors[index]]
                        cursors[index] += 1
                        if seen.insert(term.lowercased()).inserted {
                            terms.append(term)
                            break
                        }
                    }
                }
            }
        }
        return terms
    }

    /// Permit regional variants (en-US/en_GB) without applying English packs to
    /// an unspecified language. Callers supply the person's configured languages.
    private static func languageBase(_ language: String) -> String {
        language.replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-").first.map(String.init) ?? ""
    }

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
    }

    /// Bounded wire validation, retaining well-formed unknown IDs for peers with
    /// a different catalog. Off may overlap On: Off deliberately wins.
    static func validSelection(_ ids: [String]) -> Bool {
        ids.count <= 100 && Set(ids).count == ids.count && ids.allSatisfy(validID)
    }
}

extension VocabularyHint {
    /// Shared by dictation and the Dictionary preview. All context is supplied
    /// by the caller: no second repository, settings lookup or app discovery.
    static func vocabularyHintInput(entries: [DictionaryEntryDTO], ownerNames: [String], voiceLaunch: [String],
                                    forVoiceCommandSession: Bool, automatic: Bool, on: [String], off: [String],
                                    installedBundleIDs: Set<String>, destinationBundleID: String?, languages: [String],
                                    catalog: [VocabularyPack] = VocabularyPackCatalog.all) -> VocabularyHintInput {
        var input = VocabularyHintInput(ownerNames: ownerNames, voiceLaunch: voiceLaunch, isVoiceLaunch: forVoiceCommandSession)
        for entry in entries where entry.isForgotten != true {
            let target = entry.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            let word = target.isEmpty ? entry.pattern : target
            if entry.isStarred == true { input.starred.append(word) }
            else { input.ranked.append(VocabularyHintWord(text: word, useCount: entry.useCount ?? 0, lastUsedAt: entry.lastUsedAt)) }
        }
        input.includeFields(automatic: automatic, on: on, off: off, installedBundleIDs: installedBundleIDs,
                            destinationBundleID: destinationBundleID, languages: languages, catalog: catalog)
        return input
    }
}

/// LaunchServices answers only known bundle IDs; no recursive filesystem scan,
/// app launches, contacts or history. The actor runs queries off the main actor
/// and caches both hits and misses for five minutes. It is never queried at load.
enum InstalledApps {
    private static let cache = InstalledAppCache()

    static func bundleIDs() async -> Set<String> {
        await cache.bundleIDs()
    }
}

private actor InstalledAppCache {
    private var cached: Set<String> = []
    private var refreshedAt: Date?

    func bundleIDs() -> Set<String> {
        if let refreshedAt, Date().timeIntervalSince(refreshedAt) < 300 { return cached }
        let candidates = Set(VocabularyPackCatalog.all.flatMap(\.apps))
        cached = Set(candidates.filter { id in
            guard let urls = LSCopyApplicationURLsForBundleIdentifier(id as CFString, nil)?.takeRetainedValue() else { return false }
            return CFArrayGetCount(urls) > 0
        })
        refreshedAt = Date()
        return cached
    }
}

// Shared construction seam for production recognition and synthetic tests.
extension VocabularyHintInput {
    mutating func includeFields(automatic: Bool, on: [String], off: [String], installedBundleIDs: Set<String>,
                               destinationBundleID: String?, languages: [String],
                               catalog: [VocabularyPack] = VocabularyPackCatalog.all) {
        nearby = []
        packs = VocabularyPackCatalog.activeTerms(in: catalog, automatic: automatic, on: on, off: off,
            installedBundleIDs: installedBundleIDs, destinationBundleID: destinationBundleID, languages: languages)
    }
}
