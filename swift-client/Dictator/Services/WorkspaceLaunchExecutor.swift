import Foundation

/// Desktop access stays behind this boundary so plans and recovery can be tested
/// without reading or changing the machine's real windows.
@MainActor
protocol WorkspaceLaunchAdapter: AnyObject {
    var isAccessibilityGranted: Bool { get }
    var monotonicTime: TimeInterval { get }
    var frontmostBundleID: String? { get }
    var runningBundleIDs: Set<String> { get }
    func isAppRunning(bundleID: String) -> Bool
    func isAppInstalled(bundleID: String) -> Bool
    func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool
    /// True when each launch makes a window of its own. Other browsers usually
    /// add a tab, so there is no new window to wait for.
    func opensOwnWindow(bundleID: String) -> Bool
    /// Every browser on this Mac, read fresh.
    func installedBrowsers() async -> [WorkspaceBrowserInfo]
    /// Opens these addresses in a browser, without bringing it to the front.
    func openTabs(bundleID: String, profileDirectory: String?, urls: [String], timeout: TimeInterval) async throws -> Bool
    func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool
    var dictatorBundleID: String { get }
    func liveWindowOrder(deadline: TimeInterval) async -> [WorkspaceStackWindow]
    func makeAppFrontmost(bundleID: String, deadline: TimeInterval) async throws
    func raiseWindow(id: String, deadline: TimeInterval) async throws
    func setMinimized(id: String, minimized: Bool) async throws
    func requestPermission()
    func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) async throws -> WorkspaceSnapshot
    func moveWindow(id: String, to frame: WorkspaceRect) async throws
    /// Sends a window toward a parked spot and says where it landed. macOS nudges
    /// a window back from the edge, so unlike `moveWindow` this can't insist on
    /// an exact place: the caller decides if the result is out of the way.
    func parkWindow(id: String, at frame: WorkspaceRect) async throws -> WorkspaceRect
    func restoreWindow(_ window: WorkspaceWindow) async throws
    func hideApp(bundleID: String) async throws -> Bool
    /// Shows an app that may be hidden, whoever hid it. True if it was hidden.
    func showApp(bundleID: String) async throws -> Bool
    /// Hides an app `showApp` showed, for Undo.
    func rehideApp(bundleID: String) async throws
    /// False when the process shown by the run has exited or been replaced.
    func canRehideApp(bundleID: String) -> Bool
    func unhideApp(bundleID: String) async throws
    func retainWindows(ids: Set<String>)
}

extension WorkspaceLaunchAdapter {
    var monotonicTime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var frontmostBundleID: String? { nil }
    var runningBundleIDs: Set<String> { [] }
    func isAppRunning(bundleID: String) -> Bool { false }
    func isAppInstalled(bundleID: String) -> Bool { false }
    func openApp(bundleID: String, timeout: TimeInterval) async throws -> Bool { false }
    func opensOwnWindow(bundleID: String) -> Bool { true }
    func installedBrowsers() async -> [WorkspaceBrowserInfo] { [] }
    func openTabs(bundleID: String, profileDirectory: String?, urls: [String], timeout: TimeInterval) async throws -> Bool { false }
    func parkWindow(id: String, at frame: WorkspaceRect) async throws -> WorkspaceRect {
        try await moveWindow(id: id, to: frame)
        return frame
    }
    func showApp(bundleID: String) throws -> Bool { false }
    func rehideApp(bundleID: String) throws {}
    func canRehideApp(bundleID: String) -> Bool { true }
    func waitForFirstWindow(bundleID: String, timeout: TimeInterval) async throws -> Bool { false }
    var dictatorBundleID: String { "dev.noamlitt.dictator" }
    func liveWindowOrder(deadline: TimeInterval) async -> [WorkspaceStackWindow] { [] }
    func makeAppFrontmost(bundleID: String, deadline: TimeInterval) async throws {}
    func raiseWindow(id: String, deadline: TimeInterval) async throws {}

    /// Re-read between passes: activating one app can raise its other windows
    /// above a window that was already correct. Failures never stop siblings.
    func applyWindowStack(_ wanted: [String], snapshot: WorkspaceSnapshot, deadline: TimeInterval) async -> WorkspaceStackResult {
        let previous = frontmostBundleID
        var result = WorkspaceStackResult()
        var attempted = Set<String>(), failed = Set<String>()
        func lifts(_ live: [WorkspaceStackWindow]) -> [String] {
            WorkspaceWindowStack.lifts(wanted: wanted, frontToBack: live,
                ignoring: Set(live.filter { $0.bundleID == dictatorBundleID }.map(\.id)))
        }
        var live = await liveWindowOrder(deadline: deadline)
        for _ in 0..<3 {
            let needed = lifts(live)
            guard !needed.isEmpty, !Task.isCancelled, monotonicTime < deadline else { break }
            result.passes += 1
            for id in needed {
                guard !Task.isCancelled, monotonicTime < deadline else { break }
                attempted.insert(id)
                do {
                    try await raiseWindow(id: id, deadline: deadline)
                    result.liftedIDs.insert(id)
                } catch { failed.insert(id) }
            }
            live = await liveWindowOrder(deadline: deadline)
        }
        // A successful AX acknowledgement alone does not establish stacking.
        if !attempted.isEmpty { failed.formUnion(lifts(live)) }
        if !attempted.isEmpty,
           WorkspaceWindowStack.shouldRestoreFocus(previousBundleID: previous, dictatorBundleID: dictatorBundleID,
                                                   frontToBack: live, lifted: result.liftedIDs),
           let previous, !Task.isCancelled, monotonicTime < deadline {
            do {
                try await makeAppFrontmost(bundleID: previous, deadline: deadline)
                result.focusRestored = true
            } catch { /* Focus restoration must not fail the routine either. */ }
        }
        let wantedIDs = Set(wanted)
        if result.focusRestored { live = await liveWindowOrder(deadline: deadline) }
        result.finalBundleOrder = live.filter { wantedIDs.contains($0.id) }.map(\.bundleID)
        for id in wanted where failed.contains(id) {
            if let window = snapshot.windows.first(where: { $0.id == id }) {
                let note = "\(window.appName.isEmpty ? window.bundleID : window.appName) wouldn't come to the front."
                if !result.notes.contains(note) { result.notes.append(note) }
            }
        }
        return result
    }
    func setMinimized(id: String, minimized: Bool) async throws {
        throw WorkspaceLaunchError.unavailable("An app wouldn't bring its window back.")
    }

    func restoreWindow(_ window: WorkspaceWindow) async throws {
        try await moveWindow(id: window.id, to: window.frame)
        if window.isMinimized { try await setMinimized(id: window.id, minimized: true) }
    }
}

struct WorkspaceRecovery: Equatable {
    var windows: [WorkspaceWindow] = []
    var hiddenBundleIDs: [String] = []
    /// Apps a group showed, hidden again by Undo.
    var shownBundleIDs: [String] = []
    var frontBundleID: String? = nil
    var isEmpty: Bool { windows.isEmpty && hiddenBundleIDs.isEmpty && shownBundleIDs.isEmpty }
    var windowIDs: Set<String> { Set(windows.map(\.id)) }

    /// This recovery for a run that also showed `shown` with `front` in
    /// front, with `originals` replacing any saved frame of the same windows.
    func merging(originals: [WorkspaceWindow], shown: [String], front: String?) -> WorkspaceRecovery {
        var merged = self
        merged.frontBundleID = front
        merged.shownBundleIDs = shown
        for window in originals {
            merged.windows.removeAll { $0.id == window.id }
            merged.windows.append(window)
        }
        return merged
    }
}

struct WorkspaceStackResult {
    var passes = 0
    var liftedIDs = Set<String>()
    var finalBundleOrder: [String] = []
    var focusRestored = false
    var notes: [String] = []
    var diagnostic: String {
        "workspace: stack passes=\(passes) lifted=\(liftedIDs.count) order=\(finalBundleOrder.joined(separator: ",")) focusBack=\(focusRestored ? 1 : 0)"
    }
}

struct WorkspaceExecutionResult {
    var completed = 0
    var movedWindowIDs = Set<String>()
    var recovery = WorkspaceRecovery()
    var failures: [String] = []
    var stack: WorkspaceStackResult?
    var notes: [String] = []
}

/// What opening tab sets did on this Mac. Counts and plain notes only.
struct WorkspaceTabRun: Equatable {
    var tabsOpened = 0
    var windowsOpened = 0
    var windowsReused = 0
    var tracker = WorkspaceTabWindowTracker()
    var moved: [WorkspaceWindow] = []
    var movedWindowIDs: Set<String> = []
    var observed: [String: WorkspaceWindow] = [:]
    var displays: [WorkspaceDisplay] = []
    /// Browsers that weren't running before this run started them.
    var started: Set<String> = []
    var notes: [String] = []
    var failedBrowsers: [String] = []
    var slowBrowsers: [String] = []

    mutating func merge(_ other: WorkspaceTabRun) {
        tabsOpened += other.tabsOpened
        windowsOpened += other.windowsOpened
        windowsReused += other.windowsReused
        tracker = other.tracker
        movedWindowIDs.formUnion(other.movedWindowIDs)
        observed.merge(other.observed) { _, new in new }
        if !other.displays.isEmpty { displays = other.displays }
        for window in other.moved where !moved.contains(where: { $0.id == window.id }) { moved.append(window) }
        started.formUnion(other.started)
        for note in other.notes where !notes.contains(note) { notes.append(note) }
        for name in other.failedBrowsers where !failedBrowsers.contains(name) { failedBrowsers.append(name) }
        for name in other.slowBrowsers where !slowBrowsers.contains(name) { slowBrowsers.append(name) }
    }

    func failure(macName: String) -> String? {
        var lines: [String] = []
        if !failedBrowsers.isEmpty { lines.append(WorkspaceTabWords.failure(browsers: failedBrowsers, macName: macName)) }
        if !slowBrowsers.isEmpty { lines.append(WorkspaceTabWords.slow(browsers: slowBrowsers, macName: macName)) }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

@MainActor
enum WorkspaceLaunchExecutor {
    /// Opens this Mac's tab sets, in order.
    static func openTabSets(in routine: WorkspaceRoutine, macID: String, aliases: Set<String>, macName: String,
                            adapter: WorkspaceLaunchAdapter, deadline: TimeInterval, afterLastWindowStep: Bool? = nil,
                            tracker: WorkspaceTabWindowTracker = WorkspaceTabWindowTracker(),
                            routines: [WorkspaceRoutine]? = nil) async -> WorkspaceTabRun {
        let actions = afterLastWindowStep.map { routine.tabActions(afterLastWindowStep: $0) } ?? routine.actions
        let sets = actions.flatMap { $0.tabSets ?? [] }.filter { $0.isLocal(macID, aliases: aliases) }
        var result = WorkspaceTabRun()
        result.tracker = tracker
        guard !sets.isEmpty else { return result }
        let browsers = await adapter.installedBrowsers()
        func failed(_ set: WorkspaceTabSet) {
            if !result.failedBrowsers.contains(set.browserName) { result.failedBrowsers.append(set.browserName) }
        }
        func note(_ text: String) {
            if !result.notes.contains(text) { result.notes.append(text) }
        }
        func capture(_ bundleID: String) async throws -> WorkspaceSnapshot {
            let snapshot = try await adapter.capture(lastActivatedAt: [:], excluding: [], preferredFrontmostBundleID: nil,
                windowBundleIDs: [bundleID], applicationBundleIDs: [bundleID])
            result.displays = snapshot.displays
            for window in snapshot.windows { result.observed[window.id] = window }
            let unknown = snapshot.applications.contains { $0.bundleID == bundleID && $0.isHidden }
                || !(snapshot.skipped ?? []).isEmpty || !snapshot.notes.isEmpty
            let retained = result.tracker.windows.values.filter { $0.bundleID != bundleID || unknown || $0.returnPending }.map(\.windowID)
            let knownRoutines = routines ?? [routine] + result.tracker.windows.values.map { window in
                WorkspaceRoutine(id: window.routineID, name: "", actions: [.openingTabs([
                    WorkspaceTabSet(id: window.setID, macID: macID, macName: macName,
                        browserBundleID: window.bundleID, browserName: "", urls: [])
                ])])
            }
            let previous = Array(result.tracker.windows.values)
            result.tracker.prune(liveWindowIDs: Set(snapshot.windows.map(\.id)).union(retained), routines: knownRoutines)
            // A deleted set may still be parked. Keep its handle until the
            // controller can bring it home; unobserved apps are unknown here.
            for tracked in previous where result.tracker.window(forSet: tracked.setID) == nil {
                if tracked.returnPending || tracked.bundleID != bundleID || unknown || snapshot.windows.contains(where: {
                    $0.id == tracked.windowID && (tracked.parked || WorkspaceParking.isParked($0.frame, displays: snapshot.displays))
                }) { result.tracker.record(tracked) }
            }
            return snapshot
        }
        func place(_ window: WorkspaceWindow, set: WorkspaceTabSet, snapshot: WorkspaceSnapshot, reusing: Bool) async {
            var tracked = result.tracker.window(forSet: set.id) ?? WorkspaceTabWindow(
                setID: set.id, routineID: routine.id, windowID: window.id, bundleID: set.browserBundleID, home: window.frame,
                signature: set.signature)
            var target: WorkspaceRect?
            if let monitor = set.monitor, let position = set.position {
                let resolution = monitor.resolve(in: snapshot, macName: macName)
                if let text = resolution.note { note(text) }
                target = resolution.display.map { position.frame(on: $0.visibleFrame) }
            } else if tracked.parked || WorkspaceParking.isParked(window.frame, displays: snapshot.displays), let home = tracked.home {
                var original = window; original.frame = home; original.displayID = nil
                target = WorkspaceGeometry.restorationFrame(for: original, displays: snapshot.displays)
            }
            // Record before attempting a move: an app can apply half a move and fail.
            result.tracker.record(tracked)
            if let target, target != window.frame {
                var original = window
                // Undo must never send a reused window back to a parked spot.
                if tracked.parked || WorkspaceParking.isParked(window.frame, displays: snapshot.displays), let home = tracked.home {
                    original.frame = home
                }
                if !result.moved.contains(where: { $0.id == original.id }) { result.moved.append(original) }
                do {
                    try await adapter.moveWindow(id: window.id, to: target)
                    result.movedWindowIDs.insert(window.id)
                    tracked.home = target
                    tracked.parked = false
                    result.tracker.record(tracked)
                    var placed = window; placed.frame = target
                    result.observed[window.id] = placed
                } catch { note("\(set.browserLabel) opened, but its window couldn't be placed.") }
            } else if tracked.parked, target == window.frame {
                // macOS can happen to put a pushed-back window exactly at home.
                tracked.parked = false
                result.tracker.record(tracked)
            }
            if reusing {
                do { try await adapter.raiseWindow(id: window.id, deadline: deadline) }
                catch { note("\(set.browserLabel) wouldn't come to the front.") }
            }
        }
        for (index, set) in sets.enumerated() {
            guard !Task.isCancelled, adapter.monotonicTime < deadline else {
                for remaining in sets[index...] {
                    failed(remaining)
                    note("\(remaining.browserLabel) didn't open in time on \(macName), so its tabs didn't open.")
                }
                break
            }
            var before: WorkspaceSnapshot?
            if adapter.isAccessibilityGranted {
                // Capture the old browser before the new one: editing can change
                // browsers as well as addresses, profile and placement.
                if var tracked = result.tracker.window(forSet: set.id), tracked.signature != set.signature {
                    tracked.returnPending = true
                    result.tracker.record(tracked)
                    if let snapshot = try? await capture(tracked.bundleID),
                       let window = snapshot.windows.first(where: { $0.id == tracked.windowID }) {
                        if tracked.parked || WorkspaceParking.isParked(window.frame, displays: snapshot.displays) {
                            if let home = tracked.home {
                                var original = window
                                original.frame = home
                                original.displayID = nil
                                if let target = WorkspaceGeometry.restorationFrame(for: original, displays: snapshot.displays) {
                                    if !result.moved.contains(where: { $0.id == window.id }) { result.moved.append(original) }
                                    do {
                                        try await adapter.moveWindow(id: window.id, to: target)
                                        result.movedWindowIDs.insert(window.id)
                                        var returned = window; returned.frame = target
                                        result.observed[window.id] = returned
                                        result.tracker.forget(setID: set.id)
                                    } catch { note("A browser window couldn't come back. Try Bring back again.") }
                                }
                            }
                        } else { result.tracker.forget(setID: set.id) }
                    }
                }
                before = try? await capture(set.browserBundleID)
                if let snapshot = before, let tracked = result.tracker.window(forSet: set.id),
                   tracked.routineID == routine.id, tracked.bundleID == set.browserBundleID, !tracked.returnPending,
                   let window = snapshot.windows.first(where: { $0.id == tracked.windowID }) {
                    await place(window, set: set, snapshot: snapshot, reusing: true)
                    result.windowsReused += 1
                    continue
                }
            }
            if let blocked = WorkspaceTabWords.blocked(set, browsers: browsers, macName: macName, preview: false) {
                failed(set)
                note(blocked)
                continue
            }
            let failure = "\(set.browserLabel) couldn't open on \(macName), so its tabs didn't open."
            guard !set.urls.isEmpty, set.urls.allSatisfy(WorkspaceTabAddress.isAllowed) else {
                failed(set)
                note(failure)
                continue
            }
            let wasRunning = adapter.isAppRunning(bundleID: set.browserBundleID)
            let windowDeadline = min(deadline, adapter.monotonicTime + 8)
            do {
                guard try await adapter.openTabs(bundleID: set.browserBundleID, profileDirectory: set.profile?.directory,
                                                 urls: set.urls, timeout: windowDeadline - adapter.monotonicTime) else {
                    failed(set)
                    note(failure)
                    continue
                }
            } catch is WorkspaceTabOpenTimedOut {
                if !result.slowBrowsers.contains(set.browserName) { result.slowBrowsers.append(set.browserName) }
                note(WorkspaceTabWords.slow(browsers: [set.browserLabel], macName: macName))
                continue
            } catch {
                // System errors can contain addresses or profile paths.
                failed(set)
                note(failure)
                continue
            }
            result.tabsOpened += set.urls.count
            result.windowsOpened += 1
            if !wasRunning {
                result.started.insert(set.browserBundleID)
                let remaining = windowDeadline - adapter.monotonicTime
                if remaining > 0, !Task.isCancelled {
                    // The launch succeeded even if the first window is slow.
                    _ = try? await adapter.waitForFirstWindow(bundleID: set.browserBundleID, timeout: remaining)
                }
            }
            let wantsPlace = set.position != nil
            if adapter.isAccessibilityGranted, before != nil,
               wantsPlace || adapter.opensOwnWindow(bundleID: set.browserBundleID) {
                let oldIDs = Set(before?.windows.map(\.id) ?? [])
                let pollDeadline = min(deadline, adapter.monotonicTime + 3)
                let wallDeadline = ProcessInfo.processInfo.systemUptime + 3
                var found = false, ambiguous = false
                func candidates(_ snapshot: WorkspaceSnapshot) -> [WorkspaceWindow] {
                    snapshot.windows.filter {
                        $0.bundleID == set.browserBundleID && !oldIDs.contains($0.id) && !result.tracker.windowIDs.contains($0.id)
                    }
                }
                // A separate wall deadline also bounds adapters with a synthetic clock.
                repeat {
                    if let snapshot = try? await capture(set.browserBundleID) {
                        let new = candidates(snapshot)
                        if new.count > 1 { ambiguous = true; break }
                        if new.count == 1 {
                            // A personal window can appear at the same time as the
                            // launch. Require one more observation before owning it.
                            try? await Task.sleep(for: .milliseconds(150))
                            if !Task.isCancelled, adapter.monotonicTime < deadline,
                               let confirmed = try? await capture(set.browserBundleID) {
                                let windows = candidates(confirmed)
                                if windows.count > 1 { ambiguous = true; break }
                                if let window = windows.first, windows.count == 1, window.id == new[0].id,
                                   result.tracker.window(forSet: set.id) == nil {
                                    await place(window, set: set, snapshot: confirmed, reusing: false)
                                    found = true
                                }
                            }
                            break
                        }
                    }
                    guard !Task.isCancelled, adapter.monotonicTime < pollDeadline,
                          ProcessInfo.processInfo.systemUptime < wallDeadline else { break }
                    try? await Task.sleep(for: .milliseconds(50))
                } while !Task.isCancelled
                if wantsPlace {
                    if ambiguous { note("\(set.browserLabel) opened, but Dictator couldn't tell which window was its own, so it wasn't placed.") }
                    else if !found { note("\(set.browserLabel) opened, but Dictator couldn't find its window, so it wasn't placed.") }
                }
            } else if adapter.isAccessibilityGranted && wantsPlace {
                note("\(set.browserLabel) opened, but Dictator couldn't find its window, so it wasn't placed.")
            }
        }
        return result
    }

    /// Visible windows count first. Multiple steps reuse the same brought-back
    /// windows; they do not each expand the app's window count.
    nonisolated static func windowsToBringBack(in routine: WorkspaceRoutine, snapshot: WorkspaceSnapshot,
                                   macID: String?, aliases: Set<String>) -> [WorkspaceWindow] {
        var needed: [String: Int] = [:]
        for action in routine.actions {
            if action.isRememberedLayout, let layout = action.localLayout(macID, aliases: aliases) {
                for id in layout.bundleIDs {
                    needed[id] = max(needed[id] ?? 0, layout.windows.filter { $0.bundleID == id }.count)
                }
            } else if action.isPlacement {
                for app in action.localApps(macID, aliases: aliases) { needed[app.id] = max(needed[app.id] ?? 0, 1) }
            }
        }
        return needed.keys.sorted().flatMap { id -> [WorkspaceWindow] in
            let visible = snapshot.windows.filter { $0.bundleID == id && !$0.isMinimized && $0.frame.isUsable }.count
            return Array(snapshot.windows.filter { $0.bundleID == id && $0.isMinimized && $0.frame.isUsable }
                .prefix(max(0, needed[id]! - visible)))
        }
    }

    static func bringBack(_ windows: [WorkspaceWindow], adapter: WorkspaceLaunchAdapter, deadline runDeadline: TimeInterval? = nil) async -> (windows: [WorkspaceWindow], notes: [String: String]) {
        var restored: [WorkspaceWindow] = [], failed = Set<String>(), notes: [String: String] = [:]
        let deadline = min(adapter.monotonicTime + 5, runDeadline ?? .infinity)
        for window in windows {
            do {
                guard !Task.isCancelled, adapter.monotonicTime < deadline else { throw WorkspaceLaunchError.unavailable("Preparation took too long") }
                try await adapter.setMinimized(id: window.id, minimized: false)
                restored.append(window)
            } catch {
                if failed.insert(window.bundleID).inserted {
                    notes[window.bundleID] = "\(window.appName.isEmpty ? window.bundleID : window.appName) wouldn't bring a minimized window back. Try it from the Dock."
                }
            }
        }
        return (restored, notes)
    }

    /// Opens only this Mac's apps. Opening and waiting share eight seconds per
    /// app and leave ten seconds of the voice budget for capture and movement.
    static func openMissing(in routine: WorkspaceRoutine, macID: String, aliases: Set<String>,
                            macName: String, adapter: WorkspaceLaunchAdapter) async -> (opened: Set<String>, notes: [String], unavailable: Set<String>, notesByApp: [String: String]) {
        let deadline = adapter.monotonicTime + VoiceLaunchReadiness.workspaceRunBudget - 10
        var seen = Set<String>(), opened = Set<String>(), unavailable = Set<String>(), notes: [String: String] = [:]
        for action in routine.actions where (action.isPlacement || action.isRememberedLayout) && action.openMissingApps == true {
            for app in action.localApps(macID, aliases: aliases) where seen.insert(app.id).inserted {
                let id = app.id, name = app.name
                guard !adapter.isAppRunning(bundleID: id) else { continue }
                guard adapter.isAppInstalled(bundleID: id) else {
                    unavailable.insert(id)
                    notes[id] = "\(name) isn't installed on \(macName), so it wasn't placed."
                    continue
                }
                let appDeadline = min(deadline, adapter.monotonicTime + 8)
                guard !Task.isCancelled, appDeadline > adapter.monotonicTime else {
                    unavailable.insert(id)
                    notes[id] = "\(name) didn't open in time on \(macName), so it wasn't placed."
                    continue
                }
                do {
                    let didOpen = try await adapter.openApp(bundleID: id, timeout: appDeadline - adapter.monotonicTime)
                    if didOpen { opened.insert(id) }
                    let remaining = appDeadline - adapter.monotonicTime
                    var ready = false
                    if didOpen && remaining > 0 { ready = try await adapter.waitForFirstWindow(bundleID: id, timeout: remaining) }
                    if !ready {
                        unavailable.insert(id)
                        notes[id] = "\(name) didn't show a window in time on \(macName), so it wasn't placed."
                    }
                } catch {
                    unavailable.insert(id)
                    if adapter.isAppRunning(bundleID: id) { opened.insert(id) }
                    notes[id] = "\(name) couldn't open on \(macName), so it wasn't placed."
                }
            }
        }
        return (opened, notes.keys.sorted().map { notes[$0]! }, unavailable, notes)
    }

    /// Yield between desktop operations so a long routine does not monopolize
    /// the main run loop. The individual Accessibility calls also have timeouts.
    static func applyCooperatively(_ plan: WorkspacePlan, snapshot: WorkspaceSnapshot, adapter: WorkspaceLaunchAdapter,
                                  deadline runDeadline: TimeInterval? = nil, isAppStillIdle: ((String) -> Bool)? = nil) async -> WorkspaceExecutionResult {
        var result = WorkspaceExecutionResult()
        let deadline = min(adapter.monotonicTime + 5, runDeadline ?? .infinity)
        for operation in plan.operations {
            await Task.yield()
            guard !Task.isCancelled, adapter.monotonicTime < deadline else {
                result.failures.append("The routine took too long, so Dictator stopped it.")
                break
            }
            if case .hideApp(let id) = operation, isAppStillIdle?(id) == false {
                result.failures.append("You used an app while the routine ran, so Dictator didn't hide it.")
                break
            }
            let step = await apply(WorkspacePlan(operations: [operation]), snapshot: snapshot, adapter: adapter)
            result.notes += step.notes
            result.completed += step.completed
            result.movedWindowIDs.formUnion(step.movedWindowIDs)
            for window in step.recovery.windows where !result.recovery.windowIDs.contains(window.id) {
                result.recovery.windows.append(window)
            }
            for id in step.recovery.hiddenBundleIDs where !result.recovery.hiddenBundleIDs.contains(id) {
                result.recovery.hiddenBundleIDs.append(id)
            }
            if !step.failures.isEmpty { result.failures += step.failures; break }
        }
        if !plan.windowStack.isEmpty {
            if result.failures.isEmpty {
                result.stack = await adapter.applyWindowStack(plan.windowStack, snapshot: snapshot, deadline: runDeadline ?? deadline)
            } else {
                // Keep one stack diagnostic for every run with a stack plan,
                // even when geometry stopped before any lift could be tried.
                let wanted = Set(plan.windowStack)
                let live = await adapter.liveWindowOrder(deadline: runDeadline ?? deadline)
                var stack = WorkspaceStackResult()
                stack.finalBundleOrder = live.filter { wanted.contains($0.id) }.map(\.bundleID)
                result.stack = stack
            }
        }
        return result
    }

    static func restoreCooperatively(_ recovery: WorkspaceRecovery, adapter: WorkspaceLaunchAdapter) async -> WorkspaceExecutionResult {
        var result = WorkspaceExecutionResult()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var remaining = recovery
        result.recovery.frontBundleID = recovery.frontBundleID
        while !remaining.isEmpty {
            await Task.yield()
            guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else {
                result.recovery.windows += remaining.windows
                result.recovery.hiddenBundleIDs += remaining.hiddenBundleIDs
                result.recovery.shownBundleIDs += remaining.shownBundleIDs
                result.failures.append("Undo took too long and stopped partway. Try Undo again.")
                break
            }
            var single = WorkspaceRecovery(frontBundleID: recovery.frontBundleID)
            if let window = remaining.windows.popLast() {
                single.windows = [window]
            } else if let id = remaining.hiddenBundleIDs.popLast() {
                single.hiddenBundleIDs = [id]
            } else if let id = remaining.shownBundleIDs.popLast() {
                single.shownBundleIDs = [id]
            }
            let step = await restore(single, adapter: adapter)
            result.notes += step.notes
            result.completed += step.completed
            result.movedWindowIDs.formUnion(step.movedWindowIDs)
            result.recovery.windows += step.recovery.windows
            result.recovery.hiddenBundleIDs += step.recovery.hiddenBundleIDs
            result.recovery.shownBundleIDs += step.recovery.shownBundleIDs
            result.failures += step.failures
        }
        return result
    }

    static func apply(_ plan: WorkspacePlan, snapshot: WorkspaceSnapshot, adapter: WorkspaceLaunchAdapter) async -> WorkspaceExecutionResult {
        var result = WorkspaceExecutionResult()
        for operation in plan.operations {
            do {
                switch operation {
                case .moveWindow(let id, let frame):
                    guard frame.isUsable, let original = snapshot.windows.first(where: { $0.id == id }) else {
                        throw WorkspaceLaunchError.unavailable("A window closed or changed before Dictator could move it.")
                    }
                    // Include an attempted move, too: an app might accept only
                    // one of the position/size changes before reporting failure.
                    if !result.recovery.windows.contains(where: { $0.id == id }) {
                        result.recovery.windows.append(original)
                    }
                    try await adapter.moveWindow(id: id, to: frame)
                    result.movedWindowIDs.insert(id)
                case .focusApp(let bundleID):
                    do { try await adapter.makeAppFrontmost(bundleID: bundleID, deadline: adapter.monotonicTime + 2) }
                    catch { result.notes.append("The routine's app couldn't come to the front, so other apps may stay showing.") }
                case .hideOtherApp(let bundleID):
                    guard !snapshot.applications.contains(where: { $0.bundleID == bundleID && $0.isHidden }),
                          !result.recovery.hiddenBundleIDs.contains(bundleID) else { continue }
                    // If focus failed, never try to leave the screen empty.
                    guard adapter.frontmostBundleID != bundleID else {
                        result.notes.append("An app stayed showing because it is still in front.")
                        continue
                    }
                    do {
                        if try await adapter.hideApp(bundleID: bundleID) { result.recovery.hiddenBundleIDs.append(bundleID) }
                        else { continue }
                    } catch {
                        let name = snapshot.applications.first { $0.bundleID == bundleID }?.name
                        result.notes.append("\(name.flatMap { $0.isEmpty ? nil : $0 } ?? bundleID) couldn't be hidden, so it stayed showing.")
                        continue
                    }
                case .hideApp(let bundleID):
                    guard let app = snapshot.applications.first(where: { $0.bundleID == bundleID }), !app.isHidden else { continue }
                    guard try await adapter.hideApp(bundleID: bundleID) else { continue }
                    if !result.recovery.hiddenBundleIDs.contains(bundleID) { result.recovery.hiddenBundleIDs.append(bundleID) }
                }
                result.completed += 1
            } catch {
                result.failures.append(error.localizedDescription)
                // Stop a chain at its first failure. Keep recovery for all
                // attempted changes instead of losing a partially moved window.
                break
            }
        }
        return result
    }

    static func restore(_ recovery: WorkspaceRecovery, adapter: WorkspaceLaunchAdapter) async -> WorkspaceExecutionResult {
        var result = WorkspaceExecutionResult()
        result.recovery.frontBundleID = recovery.frontBundleID
        for window in recovery.windows.reversed() {
            do {
                try await adapter.restoreWindow(window)
                result.movedWindowIDs.insert(window.id)
                result.completed += 1
            } catch {
                if (error as? WorkspaceRecoveryFailure)?.canRetryRecovery != false { result.recovery.windows.append(window) }
                result.failures.append(error.localizedDescription)
            }
        }
        for bundleID in recovery.hiddenBundleIDs.reversed() {
            do {
                try await adapter.unhideApp(bundleID: bundleID)
                result.completed += 1
            } catch {
                if (error as? WorkspaceRecoveryFailure)?.canRetryRecovery != false { result.recovery.hiddenBundleIDs.append(bundleID) }
                result.failures.append(error.localizedDescription)
            }
        }
        for bundleID in recovery.shownBundleIDs.reversed() {
            guard adapter.canRehideApp(bundleID: bundleID) else { continue }
            do {
                if adapter.frontmostBundleID == bundleID,
                   let other = recovery.frontBundleID.flatMap({ $0 != bundleID && adapter.runningBundleIDs.contains($0) ? $0 : nil })
                    ?? recovery.hiddenBundleIDs.first(where: { $0 != bundleID })
                    ?? adapter.runningBundleIDs.subtracting(recovery.shownBundleIDs).sorted().first {
                    try await adapter.makeAppFrontmost(bundleID: other, deadline: adapter.monotonicTime + 1)
                }
                try await adapter.rehideApp(bundleID: bundleID)
                result.completed += 1
            } catch {
                if (error as? WorkspaceRecoveryFailure)?.canRetryRecovery != false { result.recovery.shownBundleIDs.append(bundleID) }
                result.failures.append("An app couldn't be hidden again. Try Undo again after switching apps.")
            }
        }
        return result
    }
}

enum WorkspaceLaunchError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

/// An expired process/window identity cannot become valid again on retry.
protocol WorkspaceRecoveryFailure: Error { var canRetryRecovery: Bool { get } }
