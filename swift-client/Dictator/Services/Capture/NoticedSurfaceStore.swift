import Foundation
import Observation

/// "Noticed, not saved": places the user typed into that looked like an AI
/// prompt surface but weren't saved — a tool that's switched off, an SSH
/// session to a server Dictator can't see into yet, a terminal whose Secure
/// Keyboard Entry blocks capture. One click turns each into a saving
/// surface. Stores the surface and when, never the text. Per Mac.
@MainActor
@Observable
final class NoticedSurfaceStore {
    enum Kind: String, Codable, Sendable {
        /// A known tool that is off / not set up.
        case toolOff
        /// A remote session (ssh / mosh / container) — enable remote capture.
        case remote
        /// Secure Keyboard Entry kept Dictator from seeing keystrokes.
        case secureInput
        /// A known tool on this Mac whose connector isn't set up here.
        case needsSetup
    }

    struct Notice: Codable, Identifiable, Equatable, Sendable {
        var id: String { key }
        var key: String
        var kind: Kind
        var label: String
        var toolID: String?
        var appBundleID: String?
        var remoteHost: String?
        var count: Int
        var firstSeen: Date
        var lastSeen: Date
        var dismissed: Bool
    }

    private(set) var notices: [Notice] = []
    private let url: URL?

    init(url: URL? = NoticedSurfaceStore.defaultURL) {
        self.url = url
        load()
    }

    nonisolated static var defaultURL: URL? {
        // Unit tests never read or write the user's real file.
        if NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Dictator/noticed-surfaces.json")
    }

    var active: [Notice] {
        notices.filter { !$0.dismissed }.sorted { $0.lastSeen > $1.lastSeen }
    }

    func note(_ kind: Kind, context: CaptureContext, label: String? = nil, at date: Date = Date()) {
        let key = "\(kind.rawValue)|\(kind == .remote ? (context.remoteHost ?? "-") : context.noticeKey)"
        if let index = notices.firstIndex(where: { $0.key == key }) {
            notices[index].count += 1
            notices[index].lastSeen = date
            notices[index].label = label ?? notices[index].label
        } else {
            notices.append(Notice(
                key: key,
                kind: kind,
                label: label ?? context.label(),
                toolID: context.toolID,
                appBundleID: context.appBundleID,
                remoteHost: context.remoteHost,
                count: 1,
                firstSeen: date,
                lastSeen: date,
                dismissed: false
            ))
            if notices.count > 200 {
                notices.sort { $0.lastSeen > $1.lastSeen }
                notices.removeLast(notices.count - 200)
            }
        }
        save()
    }

    func dismiss(_ notice: Notice) {
        guard let index = notices.firstIndex(where: { $0.key == notice.key }) else { return }
        notices[index].dismissed = true
        save()
    }

    /// Resolved (the user acted on it): forget it entirely so it can come
    /// back if the situation recurs.
    func resolve(_ notice: Notice) {
        notices.removeAll { $0.key == notice.key }
        save()
    }

    func resolve(where predicate: (Notice) -> Bool) {
        notices.removeAll(where: predicate)
        save()
    }

    func isDismissed(kind: Kind, context: CaptureContext) -> Bool {
        let key = "\(kind.rawValue)|\(kind == .remote ? (context.remoteHost ?? "-") : context.noticeKey)"
        return notices.contains { $0.key == key && $0.dismissed }
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([Notice].self, from: data) else { return }
        notices = decoded
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(notices) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
