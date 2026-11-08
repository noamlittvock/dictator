import Foundation

/// Where a window goes while another group is showing. macOS won't let a window
/// leave the screens, so the far corner leaves a sliver of about 1×32 points.
/// Parking is only for windows Dictator opened itself, in an app that has to
/// stay showing. Every other app is hidden instead.
enum WorkspaceParking {
    /// The frame for `window` parked past every screen, in the top-left
    /// coordinates the display frames use. Nil with no usable screen.
    static func frame(for window: WorkspaceRect, displays: [WorkspaceDisplay]) -> WorkspaceRect? {
        let screens = displays.map(\.visibleFrame).filter(\.isUsable)
        guard window.isUsable, let maxX = screens.map({ $0.x + $0.width }).max(),
              let maxY = screens.map({ $0.y + $0.height }).max() else { return nil }
        return WorkspaceRect(x: maxX - 1, y: maxY - 1, width: window.width, height: window.height)
    }
    /// True when a person couldn't reach the window's title bar.
    static func isParked(_ frame: WorkspaceRect, displays: [WorkspaceDisplay]) -> Bool {
        let screens = displays.map(\.visibleFrame).filter(\.isUsable)
        return !screens.isEmpty && !WorkspaceGeometry.hasReachableTitlebar(frame, on: screens)
    }
}

/// A browser window Dictator opened for a tab set. Handles die with the app, so
/// this lives in memory, on each Mac. `home` is where it was before it was parked.
struct WorkspaceTabWindow: Codable, Equatable, Sendable {
    var setID: String
    var routineID: String
    var windowID: String
    var bundleID: String
    var home: WorkspaceRect?
    /// What this window was opened with. If a person edits the set, it's a
    /// different window: bringing this one back would show the old pages.
    var signature: [String] = []
    /// An edited set keeps its old handle until that window can be brought home.
    var returnPending = false
    /// Dictator put this window out of the way and hasn't brought it back.
    /// Its position can't say so: macOS pushes a parked window back on screen
    /// when its hidden app shows again.
    var parked = false
}

struct WorkspaceTabWindowTracker: Equatable, Sendable {
    private(set) var windows: [String: WorkspaceTabWindow] = [:]
    init() {}
    func window(forSet setID: String) -> WorkspaceTabWindow? { windows[setID] }
    mutating func record(_ window: WorkspaceTabWindow) { windows[window.setID] = window }
    mutating func markReturned(windowID: String) {
        for (setID, window) in windows where window.windowID == windowID { windows[setID]?.parked = false }
    }
    mutating func forget(setID: String) { windows[setID] = nil }
    /// Drops windows that no longer exist. `routines` drops sets a person removed.
    mutating func prune(liveWindowIDs: Set<String>?, routines: [WorkspaceRoutine]) {
        windows = windows.filter { _, window in
            (liveWindowIDs?.contains(window.windowID) ?? true)
                && routines.contains { routine in
                    routine.id == window.routineID && routine.actions.contains { action in
                        action.isTabStep && (action.tabSets ?? []).contains { $0.id == window.setID }
                    }
                }
        }
    }
    /// Windows of `bundleIDs` that belong to a set outside `routineID`.
    func others(than routineID: String, in bundleIDs: Set<String>) -> [WorkspaceTabWindow] {
        windows.values.filter { $0.routineID != routineID && bundleIDs.contains($0.bundleID) }
            .sorted { $0.setID < $1.setID }
    }
    var windowIDs: Set<String> { Set(windows.values.map(\.windowID)) }
}

/// Written while any window is parked, so a crash can't strand it. Each Mac
/// keeps its own. No titles: only the app and where the window belongs.
struct WorkspaceParkedRecord: Codable, Equatable, Sendable {
    var bundleID: String
    var home: WorkspaceRect
    var savedAt: Date? = nil
    var parkedAt: WorkspacePoint? = nil
}

/// What "Show only this routine's windows" means on one Mac.
struct WorkspaceFocusPlan: Equatable, Sendable {
    /// Apps that must be showing, in the order the routine names them.
    var groupApps: [String] = []
    /// Showing apps outside the group, sorted.
    var appsToHide: [String] = []
    /// The app to bring forward first, because macOS won't hide the front app.
    var focusApp: String?
    var notes: [String] = []
}

extension WorkspaceRoutine {
    /// The apps in this routine on this Mac, with no duplicates, in step order,
    /// including the browsers of its tab sets and `keepVisible`.
    func groupApps(macID: String?, aliases: Set<String>) -> [String] {
        var seen = Set<String>()
        let apps = actions.flatMap { action -> [String] in
            guard action.kind == .arrangeWindows else { return [] }
            if action.isTabStep {
                return (action.tabSets ?? []).filter { $0.isLocal(macID, aliases: aliases) }.map(\.browserBundleID)
            }
            return action.localApps(macID, aliases: aliases).map(\.id)
        }
        return (apps + (keepVisible ?? [])).filter { seen.insert($0).inserted }
    }
    /// A routine only hides apps on a Mac where it has work of its own.
    func showsOnlyItsWindows(macID: String?, aliases: Set<String>) -> Bool {
        guard showOnly == true else { return false }
        var withoutKeepVisible = self
        withoutKeepVisible.keepVisible = nil
        return !withoutKeepVisible.groupApps(macID: macID, aliases: aliases).isEmpty
    }
}

extension WorkspacePlanner {
    /// Pure so it can be tested without a Mac. `running` is every regular app,
    /// `hidden` those already hidden and `frontmost` the app in front now.
    static func focusPlan(routine: WorkspaceRoutine, macID: String?, aliases: Set<String>, running: Set<String>,
                          hidden: Set<String>, protected: Set<String>, frontmost: String?, usable: Set<String>? = nil) -> WorkspaceFocusPlan {
        guard routine.showsOnlyItsWindows(macID: macID, aliases: aliases) else { return WorkspaceFocusPlan() }
        let apps = routine.groupApps(macID: macID, aliases: aliases)
        let available = apps.filter { usable?.contains($0) ?? true }
        if let usable {
            var own = routine
            own.keepVisible = nil
            guard own.groupApps(macID: macID, aliases: aliases).contains(where: usable.contains) else {
                return WorkspaceFocusPlan(groupApps: apps, notes: ["None of this routine's apps are open, so nothing was hidden."])
            }
        }
        let toHide = running.subtracting(apps).subtracting(protected).subtracting(hidden).sorted()
        guard !toHide.isEmpty else { return WorkspaceFocusPlan(groupApps: apps) }
        let focus = frontmost.flatMap { available.contains($0) ? $0 : nil } ?? available.first { usable != nil || running.contains($0) }
        guard let focus else {
            return WorkspaceFocusPlan(groupApps: apps, notes: ["None of this routine's apps are open, so nothing was hidden."])
        }
        return WorkspaceFocusPlan(groupApps: apps, appsToHide: toHide, focusApp: focus)
    }
}
