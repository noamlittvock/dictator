import Foundation

struct WorkspaceRect: Codable, Equatable, Sendable {
    var x: Double; var y: Double; var width: Double; var height: Double
    init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    var isUsable: Bool { x.isFinite && y.isFinite && width.isFinite && height.isFinite && width > 0 && height > 0 }
}

enum WorkspaceGeometry {
    static func accessibilityFrame(_ appKitFrame: WorkspaceRect, primaryTop: Double) -> WorkspaceRect {
        WorkspaceRect(x: appKitFrame.x, y: primaryTop - appKitFrame.y - appKitFrame.height,
                      width: appKitFrame.width, height: appKitFrame.height)
    }

    /// Terminal-style windows snap to character cells. Accept a bounded
    /// size adjustment, while rejecting a minimum size that escapes its tile.
    static func restorationFrame(for window: WorkspaceWindow, displays: [WorkspaceDisplay]) -> WorkspaceRect? {
        let usable = displays.filter { $0.visibleFrame.isUsable }
        let display = usable.first { $0.id == window.displayID } ?? usable.first { $0.isMain } ?? usable.first
        guard let screen = display?.visibleFrame, window.frame.isUsable else { return nil }
        let width = min(window.frame.width, screen.width)
        let height = min(window.frame.height, screen.height)
        return WorkspaceRect(x: min(max(window.frame.x, screen.x), screen.x + screen.width - width),
                             y: min(max(window.frame.y, screen.y), screen.y + screen.height - height), width: width, height: height)
    }

    static func isAcceptableResult(_ actual: WorkspaceRect, for target: WorkspaceRect) -> Bool {
        guard actual.isUsable, target.isUsable else { return false }
        return abs(actual.x - target.x) <= 4 && abs(actual.y - target.y) <= 4
            && actual.width <= target.width + 4 && actual.height <= target.height + 4
            && target.width - actual.width <= 40 && target.height - actual.height <= 40
    }

    static func hasReachableTitlebar(_ frame: WorkspaceRect, on displays: [WorkspaceRect]) -> Bool {
        guard frame.isUsable else { return false }
        return displays.contains { screen in
            guard screen.isUsable else { return false }
            let width = min(frame.x + frame.width, screen.x + screen.width) - max(frame.x, screen.x)
            let height = min(frame.y + min(40, frame.height), screen.y + screen.height) - max(frame.y, screen.y)
            return width >= min(80, frame.width) && height >= min(20, frame.height)
        }
    }
}

struct WorkspaceDisplay: Codable, Equatable, Sendable {
    var id: String; var name: String; var visibleFrame: WorkspaceRect; var isMain: Bool
    /// Optional so older snapshots still decode. `nil` means "not known".
    var isBuiltIn: Bool?
    var stableUUID: String?
    init(id: String, name: String = "", visibleFrame: WorkspaceRect = WorkspaceRect(), isMain: Bool = false, isBuiltIn: Bool? = nil, stableUUID: String? = nil) {
        self.id = id; self.name = name; self.visibleFrame = visibleFrame; self.isMain = isMain; self.isBuiltIn = isBuiltIn; self.stableUUID = stableUUID
    }
}

struct WorkspaceWindow: Codable, Equatable, Sendable {
    var id: String; var bundleID: String; var appName: String; var frame: WorkspaceRect
    var displayID: String?; var isMinimized: Bool
    var stack: Int?
    init(id: String, bundleID: String, appName: String = "", frame: WorkspaceRect = WorkspaceRect(), displayID: String? = nil, isMinimized: Bool = false, stack: Int? = nil) {
        self.id = id; self.bundleID = bundleID; self.appName = appName; self.frame = frame; self.displayID = displayID; self.isMinimized = isMinimized; self.stack = stack
    }
}

struct WorkspaceApplication: Codable, Equatable, Sendable {
    var bundleID: String; var name: String; var isHidden: Bool; var lastActivatedAt: Date?
    init(bundleID: String, name: String = "", isHidden: Bool = false, lastActivatedAt: Date? = nil) {
        self.bundleID = bundleID; self.name = name; self.isHidden = isHidden; self.lastActivatedAt = lastActivatedAt
    }
}

struct WorkspaceSnapshot: Codable, Equatable, Sendable {
    var capturedAt: Date; var displays: [WorkspaceDisplay]; var windows: [WorkspaceWindow]
    var applications: [WorkspaceApplication]; var frontmostWindowID: String?; var notes: [String]
    /// Windows that could not be arranged, and why. Optional for older snapshots.
    var skipped: [WorkspaceSkip]?
    /// Mouse pointer in the same top-left coordinates as the display frames.
    var pointer: WorkspacePoint?
    init(capturedAt: Date = Date(), displays: [WorkspaceDisplay] = [], windows: [WorkspaceWindow] = [],
         applications: [WorkspaceApplication] = [], frontmostWindowID: String? = nil, notes: [String] = [],
         skipped: [WorkspaceSkip]? = nil, pointer: WorkspacePoint? = nil) {
        self.capturedAt = capturedAt; self.displays = displays; self.windows = windows
        self.applications = applications; self.frontmostWindowID = frontmostWindowID; self.notes = notes
        self.skipped = skipped; self.pointer = pointer
    }
}

struct WorkspaceHotkey: Codable, Equatable, Hashable {
    // Carbon modifier masks: cmd=256, shift=512, option=2048, control=4096.
    static let command: UInt32 = 256, shift: UInt32 = 512, option: UInt32 = 2048, control: UInt32 = 4096
    var keyCode: UInt32; var modifiers: UInt32
    init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    var isValid: Bool { keyCode < 127 && !(54...63).contains(keyCode)
        && modifiers & ~(Self.command | Self.shift | Self.option | Self.control) == 0
        && [Self.command, Self.option, Self.control].filter { modifiers & $0 != 0 }.count >= 2
        && !(keyCode == 53 && modifiers & (Self.command | Self.option) == Self.command | Self.option) }
}

enum WorkspaceDisplayTarget: String, Codable, CaseIterable { case main, left, right }
/// Per-Mac screen choice. A new type on purpose: `WorkspaceDisplayTarget` must
/// not gain cases, because a Mac running an earlier build would fail to read it.
enum WorkspaceDisplayChoice: String, Codable, CaseIterable, Sendable { case main, left, right, top, bottom, largest, builtIn, underPointer }
enum WorkspaceLayout: String, Codable, CaseIterable { case quarters, halves, columns }
enum WorkspaceActionKind: String, Codable, CaseIterable { case arrangeWindows, centerLastWindow, hideIdleApps }

struct WorkspaceAction: Codable, Equatable, Identifiable {
    var id: String; var kind: WorkspaceActionKind; var bundleIDs: [String]
    var display: WorkspaceDisplayTarget; var layout: WorkspaceLayout; var idleMinutes: Int
    /// Optional per-Mac screen choice, keyed by `WorkspaceMacIdentity`. Absent in
    /// routines saved by earlier builds, which ignore it when it is present.
    var displayOverrides: [String: WorkspaceDisplayChoice]?
    /// "Put windows back where they were": where each window was on each Mac
    /// when the layout was remembered, keyed by `WorkspaceMacIdentity`. When
    /// set, the step restores those places instead of tiling. The kind stays
    /// `arrangeWindows` with `bundleIDs` naming the apps, so a build that
    /// predates this field still reads the routine and tiles those apps.
    var remembered: [String: WorkspaceSavedLayout]?
    var placements: [WorkspacePlacement]?
    var openMissingApps: Bool?
    /// "Open tabs": browser windows to open, one set per window. The kind stays
    /// `arrangeWindows` with `bundleIDs` naming the browsers, so a build that
    /// predates this field still reads the routine and tiles those browsers.
    var tabSets: [WorkspaceTabSet]?
    init(id: String = UUID().uuidString, kind: WorkspaceActionKind, bundleIDs: [String] = [],
         display: WorkspaceDisplayTarget = .main, layout: WorkspaceLayout = .quarters, idleMinutes: Int = 180,
         displayOverrides: [String: WorkspaceDisplayChoice]? = nil, remembered: [String: WorkspaceSavedLayout]? = nil,
         placements: [WorkspacePlacement]? = nil, openMissingApps: Bool? = nil, tabSets: [WorkspaceTabSet]? = nil) {
        self.id = id; self.kind = kind; self.bundleIDs = bundleIDs; self.display = display; self.layout = layout; self.idleMinutes = idleMinutes
        self.displayOverrides = displayOverrides; self.remembered = remembered
        self.placements = placements; self.openMissingApps = openMissingApps; self.tabSets = tabSets
    }

    var isPlacement: Bool { kind == .arrangeWindows && placements != nil }
    var isRememberedLayout: Bool { kind == .arrangeWindows && remembered != nil }
    var isTabStep: Bool { kind == .arrangeWindows && tabSets != nil }
}

struct WorkspaceRoutine: Codable, Equatable, Identifiable {
    var id: String; var name: String; var enabled: Bool; var hotkey: WorkspaceHotkey?; var actions: [WorkspaceAction]
    /// "Show only this routine's windows": other apps hide when it runs. Optional,
    /// so an older build reads the routine and simply hides nothing.
    var showOnly: Bool?
    /// Apps that stay showing while `showOnly` hides the rest.
    var keepVisible: [String]?
    /// Opening a browser moves no windows, so a Mac that only does this, such as
    /// a server that never inserts text, doesn't need Accessibility.
    func onlyOpensTabs(macID: String?, aliases: Set<String>) -> Bool {
        !showsOnlyItsWindows(macID: macID, aliases: aliases) && !actions.isEmpty && !actions.contains { $0.doesWindowWork(macID: macID, aliases: aliases) }
    }
    /// Global test for Undo ownership and the existing view's routine-wide help.
    /// Local permission checks must use the method above instead.
    var hasWindowSteps: Bool { showOnly == true || actions.contains { !$0.isTabStep } }
    var onlyOpensTabs: Bool { !actions.isEmpty && !hasWindowSteps }

    func tabActions(afterLastWindowStep late: Bool) -> [WorkspaceAction] {
        let lastWindow = actions.lastIndex { !$0.isTabStep } ?? actions.endIndex
        // Accepted limit: a tab step between two window steps opens first.
        return actions.enumerated().filter { index, action in
            action.isTabStep && (late ? index > lastWindow : index < lastWindow)
        }.map(\.element)
    }
    init(id: String = UUID().uuidString, name: String, enabled: Bool = true, hotkey: WorkspaceHotkey? = nil, actions: [WorkspaceAction] = [],
         showOnly: Bool? = nil, keepVisible: [String]? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.hotkey = hotkey; self.actions = actions
        self.showOnly = showOnly; self.keepVisible = keepVisible
    }
}

struct WorkspaceLaunchConfig: Codable, Equatable {
    var version: Int = 1
    var routines: [WorkspaceRoutine]
    static let empty = WorkspaceLaunchConfig(routines: [])
    init(version: Int = 1, routines: [WorkspaceRoutine] = []) { self.version = version; self.routines = routines }
    static func decode(_ string: String) -> Self? {
        guard string.utf8.count <= 128 * 1024, let data = string.data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.validate().isEmpty else { return nil }
        return value
    }
    /// Preserve editable routines from an earlier hotkey policy. Invalid or
    /// duplicate shortcuts are removed and their routines disabled; this does
    /// not rewrite the saved JSON until the user saves or deletes a routine.
    static func decodeForEditing(_ string: String) -> Self? {
        guard string.utf8.count <= 128 * 1024, let data = string.data(using: .utf8),
              var config = try? JSONDecoder().decode(Self.self, from: data), config.version == 1 else { return nil }
        var seen = Set<WorkspaceHotkey>()
        for index in config.routines.indices {
            guard let key = config.routines[index].hotkey else { continue }
            if !key.isValid || (config.routines[index].enabled && !seen.insert(key).inserted) {
                config.routines[index].hotkey = nil
                config.routines[index].enabled = false
            }
        }
        return config.validate().isEmpty ? config : nil
    }
    func encoded() -> String? {
        guard validate().isEmpty, let data = try? JSONEncoder().encode(self), data.count <= 128 * 1024 else { return nil }
        return String(data: data, encoding: .utf8)
    }
    func validate() -> [String] {
        var errors: [String] = []
        if version != 1 { errors.append("Unsupported version") }
        if routines.count > 20 { errors.append("At most 20 routines are allowed") }
        if routines.contains(where: { !(1...80).contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines).count) || $0.id.isEmpty || $0.id.count > 255 }) { errors.append("Routine names must be 1–80 characters") }
        if Set(routines.map(\.id)).count != routines.count { errors.append("Routine ids must be unique") }
        if routines.contains(where: { $0.actions.isEmpty || $0.actions.count > 20 }) { errors.append("Each routine needs 1–20 steps") }
        let actionIDs = routines.flatMap { $0.actions.map(\.id) }
        if actionIDs.contains(where: { $0.isEmpty || $0.count > 255 }) || Set(actionIDs).count != actionIDs.count { errors.append("Action ids must be unique and 1–255 characters") }
        for routine in routines {
            if let keepVisible = routine.keepVisible,
               keepVisible.count > 100 || keepVisible.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 255 }) {
                errors.append("Choose at most 100 apps to keep showing")
            }
            if let hotkey = routine.hotkey, !hotkey.isValid {
                errors.append(hotkey.keyCode == 53 && hotkey.modifiers & (WorkspaceHotkey.command | WorkspaceHotkey.option) == WorkspaceHotkey.command | WorkspaceHotkey.option
                              ? "Command-Option-Escape is reserved for Force Quit"
                              : "Include at least two of Command, Control and Option in the shortcut")
            }
            for action in routine.actions {
                if let sets = action.tabSets {
                    if action.kind != .arrangeWindows || action.remembered != nil || action.placements != nil
                        || action.openMissingApps != nil || !(1...20).contains(sets.count)
                        || sets.contains(where: { !$0.isValid }) || Set(sets.map(\.id)).count != sets.count
                        || Set(sets.map(\.macID)).count > 20
                        || Set(action.bundleIDs) != Set(sets.map(\.browserBundleID)) {
                        errors.append("Each Open tabs step needs 1–20 windows with valid web addresses")
                    }
                    continue
                }
                if action.kind == .arrangeWindows || action.kind == .hideIdleApps {
                    if action.bundleIDs.isEmpty || action.bundleIDs.count > 100 || action.bundleIDs.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0.count > 255 }) { errors.append("Choose 1–100 apps for each arrange or hide step") }
                }
                if let overrides = action.displayOverrides, overrides.count > 20 || overrides.keys.contains(where: { $0.isEmpty || $0.count > 64 }) { errors.append("A step can use its own screen on at most 20 Macs") }
                if let remembered = action.remembered {
                    if remembered.count > 20 || remembered.keys.contains(where: { $0.isEmpty || $0.count > 64 }) { errors.append("Remembered layouts are limited to 20 Macs") }
                    if remembered.values.contains(where: { !$0.isValid }) { errors.append("Dictator couldn't read a remembered layout") }
                }
                if let placements = action.placements {
                    if action.kind != .arrangeWindows || action.remembered != nil || placements.isEmpty || placements.count > 100
                        || Set(placements.map(\.macID)).count > 20 || placements.contains(where: { !$0.isValid })
                        || Set(placements.map { $0.macID + "|" + $0.bundleID }).count != placements.count
                        || Set(action.bundleIDs) != Set(placements.map(\.bundleID)) {
                        errors.append("Choose up to 100 apps, once per Mac, on at most 20 Macs for a placement step")
                    }
                }
                if !(1...10080).contains(action.idleMinutes) { errors.append("The wait before hiding must be 1 minute to 7 days") }
            }
        }
        // The tracker finds a browser window by its set, across every routine.
        let setIDs = routines.flatMap { $0.actions.flatMap { Set(($0.tabSets ?? []).map(\.id)) } }
        if Set(setIDs).count != setIDs.count { errors.append("Each browser window needs its own id") }
        var seen = Set<WorkspaceHotkey>()
        for routine in routines where routine.enabled {
            if let key = routine.hotkey, !seen.insert(key).inserted { errors.append("Two routines that are on can't share a shortcut") }
        }
        return errors
    }
}

enum WorkspaceOperation: Equatable {
    case moveWindow(id: String, frame: WorkspaceRect)
    case hideApp(bundleID: String)
    /// Brings an app forward so the front app can be hidden.
    case focusApp(bundleID: String)
    /// Hides an app outside a group. Unlike `hideApp` it ignores recent use, and
    /// one app refusing is a note, not a stopped routine.
    case hideOtherApp(bundleID: String)
}
struct WorkspacePlan: Equatable {
    /// Matched Remember and Place apps windows, back to front.
    var windowStack: [String] = []
    /// Preview-only tiles for apps that have not been opened yet.
    var placementTiles: [WorkspacePreviewPicture.Tile] = []
    var operations: [WorkspaceOperation]
    var notes: [String]
    init(operations: [WorkspaceOperation] = [], notes: [String] = []) {
        self.operations = operations; self.notes = notes
    }
    mutating func addNotes(_ additions: [String]) {
        for note in additions where !notes.contains(note) { notes.append(note) }
    }
}

enum WorkspacePlanner {
    static func plan(routine: WorkspaceRoutine, snapshot: WorkspaceSnapshot, protectedBundleIDs: Set<String>, macID: String? = nil, macAliases: Set<String> = [], preview: Bool = false, unavailableApps: Set<String> = [], appNotes: [String: String] = [:], focusPlan: WorkspaceFocusPlan? = nil) -> WorkspacePlan {
        guard routine.enabled else { return WorkspacePlan(notes: ["This routine is off."]) }
        let localIDs = Set(routine.actions.flatMap { $0.localApps(macID, aliases: macAliases).map(\.id) })
        var snapshot = snapshot
        snapshot.skipped = (snapshot.skipped ?? []).filter { localIDs.contains($0.bundleID) }
        let returning = preview ? WorkspaceLaunchExecutor.windowsToBringBack(in: routine, snapshot: snapshot, macID: macID, aliases: macAliases) : []
        let returningIDs = Set(returning.map(\.id))
        for i in snapshot.windows.indices where returningIDs.contains(snapshot.windows[i].id) { snapshot.windows[i].isMinimized = false }
        snapshot.skipped = (snapshot.skipped ?? []).compactMap { skip in
            var skip = skip
            if skip.reason == .minimized { skip.count -= returning.filter { $0.bundleID == skip.bundleID }.count }
            return skip.count > 0 ? skip : nil
        }
        var result = WorkspacePlan()
        result.addNotes(snapshot.notes)
        result.addNotes(WorkspaceSkip.lines(snapshot.skipped ?? [], availableBundleIDs: Set(snapshot.windows.filter { !$0.isMinimized }.map(\.bundleID)), extraNotes: appNotes, preview: preview))
        for id in Set(returning.map(\.bundleID)).sorted() {
            let windows = returning.filter { $0.bundleID == id }
            result.addNotes(["\(windows.first?.appName ?? id): \(windows.count == 1 ? "1 minimized window will" : "\(windows.count) minimized windows will") come back."])
        }
        var hidden = Set(snapshot.applications.filter(\.isHidden).map(\.bundleID))
        var frames = snapshot.windows.reduce(into: [String: WorkspaceRect]()) { $0[$1.id] = $1.frame }
        for action in routine.actions {
            switch action.kind {
            case .arrangeWindows where action.isTabStep:
                continue
            case .arrangeWindows where action.placements != nil:
                for placement in action.placements ?? [] where placement.isLocal(macID, aliases: macAliases) {
                    let resolution = placement.monitor.resolve(in: snapshot, macName: placement.macName, preview: preview)
                    if let note = resolution.note, !result.notes.contains(note) { result.notes.append(note) }
                    guard let display = resolution.display else { continue }
                    let windows = snapshot.windows.filter { $0.bundleID == placement.bundleID && !$0.isMinimized && $0.frame.isUsable }
                    if windows.isEmpty {
                        let willOpen = preview && action.openMissingApps == true && !snapshot.applications.contains { $0.bundleID == placement.bundleID }
                            && !snapshot.windows.contains { $0.bundleID == placement.bundleID } && !(snapshot.skipped ?? []).contains { $0.bundleID == placement.bundleID }
                        if willOpen { result.placementTiles.append(.init(appName: placement.appName + " (will open)", frame: placement.position.frame(on: display.visibleFrame))) }
                        if willOpen {
                            result.addNotes(["\(placement.appName) will open on \(placement.macName): \(placement.monitor.label), \(placement.position.label)."])
                        } else if !unavailableApps.contains(placement.bundleID), let note = WorkspaceLayoutRestorer.unavailableNote(bundleID: placement.bundleID, name: placement.appName, snapshot: snapshot, openMissingApps: action.openMissingApps == true, preview: preview) {
                            result.addNotes([note])
                        }
                    }
                    let frame = placement.position.frame(on: display.visibleFrame)
                    for window in windows {
                        frames[window.id] = frame
                        result.operations.append(.moveWindow(id: window.id, frame: frame))
                    }
                    // Captures list each app's front window first. Raise back to front.
                    var stack = windows.reversed().map(\.id)
                    if let front = snapshot.frontmostWindowID, stack.contains(front) {
                        stack.removeAll { $0 == front }; stack.append(front)
                    }
                    result.windowStack += stack
                }
            case .arrangeWindows where action.remembered != nil:
                guard let layout = action.localLayout(macID, aliases: macAliases) else {
                    continue
                }
                var openingIDs = unavailableApps
                if preview && action.openMissingApps == true {
                    for app in action.localApps(macID, aliases: macAliases) where !snapshot.applications.contains(where: { $0.bundleID == app.id }) && !snapshot.windows.contains(where: { $0.bundleID == app.id }) && !(snapshot.skipped ?? []).contains(where: { $0.bundleID == app.id }) {
                        result.addNotes(["\(app.name) will open."])
                        for saved in layout.windows where saved.bundleID == app.id {
                            if let screen = layout.screens.first(where: { $0.id == saved.screenID }),
                               let display = WorkspaceLayoutRestorer.screen(for: screen, in: snapshot.displays).display {
                                result.placementTiles.append(.init(appName: app.name + " (will open)", frame: WorkspaceLayoutRestorer.frame(saved.place, on: display.visibleFrame)))
                            }
                        }
                        // Suppress the closed-app note; the preview tiles explain it.
                        openingIDs.insert(app.id)
                    }
                }
                let restore = WorkspaceLayoutRestorer.plan(layout, snapshot: snapshot, openingIDs: openingIDs, openMissingApps: action.openMissingApps == true, preview: preview)
                result.addNotes(restore.notes)
                result.windowStack += restore.windowStack
                for (id, frame) in restore.moves {
                    if frames[id] != frame { result.operations.append(.moveWindow(id: id, frame: frame)) }
                    frames[id] = frame
                }
            case .arrangeWindows:
                guard let display = target(action, in: snapshot, macID: macID, preview: preview, notes: &result.notes) else { continue }
                for id in action.bundleIDs where !(snapshot.skipped ?? []).contains(where: { $0.bundleID == id }) && !snapshot.applications.contains(where: { $0.bundleID == id }) && !snapshot.windows.contains(where: { $0.bundleID == id }) {
                    result.addNotes(["A selected app is not open on this Mac."])
                }
                let windows = snapshot.windows.filter { action.bundleIDs.contains($0.bundleID) && !$0.isMinimized }
                let valid = windows.filter { (frames[$0.id] ?? $0.frame).isUsable }
                if valid.count != windows.count { result.notes.append(preview ? "Dictator will skip some windows it can't measure." : "Dictator skipped some windows it couldn't measure.") }
                let tiles = tileFrames(in: display.visibleFrame, count: valid.count, layout: action.layout)
                if let note = narrowNote(tiles), !result.notes.contains(note) { result.notes.append(note) }
                for (window, frame) in zip(valid, tiles) { frames[window.id] = frame; result.operations.append(.moveWindow(id: window.id, frame: frame)) }
            case .centerLastWindow:
                guard let id = snapshot.frontmostWindowID, let window = snapshot.windows.first(where: { $0.id == id }), !window.isMinimized,
                      let frame = frames[id] ?? Optional(window.frame), frame.isUsable else { result.notes.append(preview ? "Dictator can't find the window you're using to center." : "Dictator couldn't find the window you're using to center."); continue }
                guard let display = target(action, in: snapshot, macID: macID, preview: preview, notes: &result.notes) else { continue }
                let w = min(frame.width, display.visibleFrame.width), h = min(frame.height, display.visibleFrame.height)
                let centered = WorkspaceRect(x: display.visibleFrame.x + (display.visibleFrame.width-w)/2, y: display.visibleFrame.y + (display.visibleFrame.height-h)/2, width: w, height: h)
                frames[id] = centered; result.operations.append(.moveWindow(id: id, frame: centered))
            case .hideIdleApps:
                let cutoff = snapshot.capturedAt.addingTimeInterval(-Double(action.idleMinutes) * 60)
                for app in snapshot.applications.sorted(by: { $0.bundleID < $1.bundleID }) where action.bundleIDs.contains(app.bundleID) {
                    if protectedBundleIDs.contains(app.bundleID) || snapshot.windows.first(where: { $0.id == snapshot.frontmostWindowID })?.bundleID == app.bundleID { continue }
                    guard let last = app.lastActivatedAt else { result.notes.append("Dictator doesn't know when you last used \(app.name.isEmpty ? app.bundleID : app.name), so \(preview ? "it won't hide" : "it wasn't hidden")."); continue }
                    if last < cutoff && !hidden.contains(app.bundleID) { result.operations.append(.hideApp(bundleID: app.bundleID)); hidden.insert(app.bundleID) }
                }
            }
        }
        if let focusPlan {
            result.addNotes(focusPlan.notes)
            if let app = focusPlan.focusApp { result.operations.append(.focusApp(bundleID: app)) }
            for app in focusPlan.appsToHide { result.operations.append(.hideOtherApp(bundleID: app)) }
            if preview, !focusPlan.appsToHide.isEmpty {
                let count = focusPlan.appsToHide.count
                result.addNotes(["Will hide \(count) other \(count == 1 ? "app" : "apps")."])
            }
        }
        return result
    }

    private static func target(_ action: WorkspaceAction, in snapshot: WorkspaceSnapshot, macID: String?, preview: Bool, notes: inout [String]) -> WorkspaceDisplay? {
        let resolution = WorkspaceDisplayResolver.resolve(action: action, macID: macID, displays: snapshot.displays, pointer: snapshot.pointer, preview: preview)
        if let note = resolution.note, !notes.contains(note) { notes.append(note) }
        return resolution.display
    }
    /// Below about this size many apps refuse to shrink a window, so a run can stop partway.
    static let narrowTileWidth = 480.0, narrowTileHeight = 320.0

    /// Says so when a layout gives windows less room than many apps accept.
    static func narrowNote(_ tiles: [WorkspaceRect]) -> String? {
        guard let width = tiles.map(\.width).min(), let height = tiles.map(\.height).min(),
              width < narrowTileWidth || height < narrowTileHeight else { return nil }
        return "Windows will be \(width < narrowTileWidth ? "narrow" : "short") in this layout on this screen. Some apps won't shrink that far, so a run may stop partway. Undo then puts back every window that moved."
    }

    static func tileFrames(in frame: WorkspaceRect, count: Int, layout: WorkspaceLayout) -> [WorkspaceRect] {
        guard count > 0, frame.isUsable else { return [] }
        let columns: Int, rows: Int
        switch layout {
        case .quarters: columns = count <= 4 ? 2 : Int(ceil(sqrt(Double(count)))); rows = count <= 4 ? 2 : Int(ceil(Double(count)/Double(columns)))
        case .halves: columns = count <= 2 ? 2 : Int(ceil(sqrt(Double(count)))); rows = Int(ceil(Double(count)/Double(columns)))
        case .columns: columns = count; rows = 1
        }
        return (0..<count).map { i in
            let col = i % columns, row = i / columns
            let w = frame.width / Double(columns), h = frame.height / Double(rows)
            return WorkspaceRect(x: frame.x + Double(col)*w, y: frame.y + Double(row)*h, width: w, height: h)
        }
    }
}
