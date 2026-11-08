import Observation
import SwiftUI

/// The one place the UI looks for history/dictionary/settings. `current` is
/// always this Mac's own store — a connected Core never changes what the UI
/// reads, it only changes what `HistorySyncEngine` replicates into it — so
/// views can hold the bundle for as long as they like.
///
/// This is also the single owner of every repository's `onChange` slot:
/// `subscribe(_:)` below is the only place in the app that may assign
/// `history.onChange`/`dictionary.onChange`/`settings.onChange`. Everything
/// else — `CoreHost`'s `repo.changed` broadcast, the sync engine, views —
/// observes `historyVersion`/`dictionaryVersion`/`settingsVersion`/`version`
/// instead of a callback.
@Observable
@MainActor
final class RepositoryHub {
    private(set) var current: Repositories

    /// Per-domain revision counters. Bumped by `subscribe(_:)` whenever the
    /// matching repository fires `onChange`, by `install(_:)` on every
    /// domain at once, and by `notifyExternalChange(_:)` for a mutation that
    /// landed outside any repository call. A view that only cares about one
    /// domain can `.onChange(of:)` just that counter.
    private(set) var historyVersion = 0
    /// Local writes only: replication refreshes the UI without triggering a push.
    private(set) var historyLocalVersion = 0
    private(set) var dictionaryLocalVersion = 0
    private(set) var dictionaryVersion = 0
    private(set) var settingsVersion = 0

    /// Bumped alongside every domain-specific version above — for call
    /// sites that don't care which domain changed, just that "something did".
    private(set) var version = 0

    init(current: Repositories) {
        self.current = current
        subscribe(current)
    }

    /// Swaps in the real on-disk bundle once persistence is available (the
    /// coordinator starts over an in-memory placeholder). Not a role
    /// change: the bundle is still this Mac's own store.
    func install(_ repositories: Repositories) {
        let previous = current
        current = repositories
        subscribe(repositories)
        previous.history.onChange = nil
        previous.dictionary.onChange = nil
        previous.settings.onChange = nil
        bumpAll()
    }

    private func subscribe(_ repositories: Repositories) {
        // Deferred a turn (rather than bumping synchronously): `onChange`
        // can fire from inside a repository call a view's own action
        // triggered, and mutating `@Observable` state synchronously in that
        // path risks "publishing changes from within view updates".
        repositories.history.onChange = { [weak self, weak repository = repositories.history] in
            let isReplica = repository?.changeIsReplica == true
            Task { @MainActor in
                if !isReplica { self?.historyLocalVersion &+= 1 }
                self?.bumpHistory()
            }
        }
        repositories.dictionary.onChange = { [weak self, weak repository = repositories.dictionary] in
            let isReplica = repository?.changeIsReplica == true
            Task { @MainActor in
                if !isReplica { self?.dictionaryLocalVersion &+= 1 }
                self?.bumpDictionary()
            }
        }
        repositories.settings.onChange = { [weak self] in
            Task { @MainActor in self?.bumpSettings() }
        }
    }

    /// Publishes a change that happened outside any repository call — e.g.
    /// a Settings-tab edit of a mirrored `AppSettings` field.
    func notifyExternalChange(_ change: RepoChange) {
        switch change {
        case .history: historyLocalVersion &+= 1; bumpHistory()
        case .dictionary: dictionaryLocalVersion &+= 1; bumpDictionary()
        case .settings: bumpSettings()
        }
    }

    private func bumpHistory() {
        historyVersion &+= 1
        version &+= 1
    }

    private func bumpDictionary() {
        dictionaryVersion &+= 1
        version &+= 1
    }

    private func bumpSettings() {
        settingsVersion &+= 1
        version &+= 1
    }

    private func bumpAll() {
        historyLocalVersion &+= 1
        dictionaryLocalVersion &+= 1
        historyVersion &+= 1
        dictionaryVersion &+= 1
        settingsVersion &+= 1
        version &+= 1
    }
}

private struct RepositoryHubKey: EnvironmentKey {
    // No default: a view reading the hub before injection is a programmer
    // error, but `EnvironmentKey` needs one — an empty local bundle over an
    // in-memory container would hide bugs, so use nil and unwrap at use sites.
    static let defaultValue: RepositoryHub? = nil
}

extension EnvironmentValues {
    var repositoryHub: RepositoryHub? {
        get { self[RepositoryHubKey.self] }
        set { self[RepositoryHubKey.self] = newValue }
    }
}
