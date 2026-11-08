import Carbon
import CryptoKit
import Foundation
import IOKit

// MARK: - Explicit app placements

/// Separate from the legacy enums so older Macs can ignore the optional field.
enum WorkspacePosition: String, Codable, CaseIterable, Sendable {
    case full, leftHalf, rightHalf, topHalf, bottomHalf, topLeft, topRight, bottomLeft, bottomRight
    case leftThird, centerThird, rightThird

    var label: String {
        switch self {
        case .full: "full screen"
        case .leftHalf: "left half"
        case .rightHalf: "right half"
        case .topHalf: "top half"
        case .bottomHalf: "bottom half"
        case .topLeft: "top-left quarter"
        case .topRight: "top-right quarter"
        case .bottomLeft: "bottom-left quarter"
        case .bottomRight: "bottom-right quarter"
        case .leftThird: "left third"
        case .centerThird: "center third"
        case .rightThird: "right third"
        }
    }

    func frame(on screen: WorkspaceRect) -> WorkspaceRect {
        let place: WorkspaceRect
        switch self {
        case .full: place = .init(width: 1, height: 1)
        case .leftHalf: place = .init(width: 0.5, height: 1)
        case .rightHalf: place = .init(x: 0.5, width: 0.5, height: 1)
        case .topHalf: place = .init(width: 1, height: 0.5)
        case .bottomHalf: place = .init(y: 0.5, width: 1, height: 0.5)
        case .topLeft: place = .init(width: 0.5, height: 0.5)
        case .topRight: place = .init(x: 0.5, width: 0.5, height: 0.5)
        case .bottomLeft: place = .init(y: 0.5, width: 0.5, height: 0.5)
        case .bottomRight: place = .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5)
        case .leftThird: place = .init(width: 1.0 / 3, height: 1)
        case .centerThird: place = .init(x: 1.0 / 3, width: 1.0 / 3, height: 1)
        case .rightThird: place = .init(x: 2.0 / 3, width: 1.0 / 3, height: 1)
        }
        return WorkspaceLayoutRestorer.frame(place, on: screen)
    }
}

enum WorkspaceMonitorChoice: Codable, Equatable, Hashable, Sendable {
    case generic(WorkspaceDisplayChoice)
    case specific(id: String, name: String)

    var label: String {
        switch self {
        case .generic(let choice): WorkspaceDisplayResolver.label(choice)
        case .specific(_, let name): name
        }
    }

    var isValid: Bool {
        switch self {
        case .generic: true
        case .specific(let id, let name): !id.isEmpty && id.count <= 64 && !name.isEmpty && name.count <= 120
        }
    }

    func resolve(in snapshot: WorkspaceSnapshot, macName: String, preview: Bool = false) -> WorkspaceDisplayResolution {
        switch self {
        case .generic(let choice):
            let result = WorkspaceDisplayResolver.resolve(choice, displays: snapshot.displays, pointer: snapshot.pointer, preview: preview)
            return .init(display: result.display, note: result.note.map { "On \(macName): \($0)" })
        case .specific(let id, let name):
            if let display = snapshot.displays.first(where: { $0.stableUUID == id && $0.visibleFrame.isUsable }) {
                return .init(display: display, note: nil)
            }
            let main = WorkspaceDisplayResolver.resolve(.main, displays: snapshot.displays, pointer: nil, preview: preview)
            return .init(display: main.display, note: main.display == nil
                ? "\(name) isn't connected to \(macName), and no screen is available."
                : "\(name) isn't connected to \(macName), so its main screen \(preview ? "will be used" : "was used").")
        }
    }
}

struct WorkspacePlacement: Codable, Equatable, Sendable {
    var bundleID: String
    var appName: String
    var macID: String
    var macName: String
    var monitor: WorkspaceMonitorChoice = .generic(.main)
    var position: WorkspacePosition = .full

    var isValid: Bool {
        !bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && bundleID.count <= 255
            && !appName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && appName.count <= 120
            && !macID.isEmpty && macID.count <= 64 && !macName.isEmpty && macName.count <= 120 && monitor.isValid
    }
    func isLocal(_ id: String?, aliases: Set<String> = []) -> Bool { macID == id || aliases.contains(macID) }
    var description: String { "\(appName) on \(monitor.label), \(position.label)" }
}

/// A setup identity is available even before an offline Mac can answer a capture.
/// Hardware keys from remembered layouts remain valid alongside this stable alias.
struct WorkspaceMacOption: Identifiable, Equatable {
    var id: String
    var name: String
    var online: Bool
    var isCurrent: Bool = false
}

extension WorkspaceAction {
    func doesWindowWork(macID: String?, aliases: Set<String>) -> Bool {
        if isTabStep { return false }
        if kind != .arrangeWindows { return true }
        if placements != nil || remembered != nil {
            return !localApps(macID, aliases: aliases).isEmpty || localLayout(macID, aliases: aliases) != nil
        }
        return true
    }

    func localLayout(_ macID: String?, aliases: Set<String> = []) -> WorkspaceSavedLayout? {
        if let macID, let layout = remembered?[macID] { return layout }
        return aliases.sorted().compactMap { remembered?[$0] }.first
    }

    func localApps(_ macID: String?, aliases: Set<String> = []) -> [(id: String, name: String)] {
        if isTabStep { return [] }
        if let placements { return placements.filter { $0.isLocal(macID, aliases: aliases) }.map { ($0.bundleID, $0.appName) } }
        if remembered != nil {
            guard let layout = localLayout(macID, aliases: aliases) else { return [] }
            return layout.bundleIDs.map { id in (id, layout.windows.first { $0.bundleID == id }?.appName ?? id) }
        }
        return bundleIDs.map { ($0, $0) }
    }

    static func placing(_ placements: [WorkspacePlacement] = [], id: String = UUID().uuidString) -> WorkspaceAction {
        WorkspaceAction(id: id, kind: .arrangeWindows, bundleIDs: Array(Set(placements.map(\.bundleID))).sorted(),
                        placements: placements, openMissingApps: true)
    }

    static func openingTabs(_ sets: [WorkspaceTabSet], id: String = UUID().uuidString) -> WorkspaceAction {
        WorkspaceAction(id: id, kind: .arrangeWindows, bundleIDs: Array(Set(sets.map(\.browserBundleID))).sorted(),
                        tabSets: sets)
    }
}

// MARK: - Snapshot additions

struct WorkspacePoint: Codable, Equatable, Sendable {
    var x: Double; var y: Double
    init(x: Double = 0, y: Double = 0) { self.x = x; self.y = y }
}

enum WorkspaceSkipReason: String, Codable, CaseIterable, Sendable { case slowToRespond, otherSpace, fullScreen, minimized, unreadable, fixedPosition, fixedSize }

/// Windows an app has that a reset could not touch, counted per app and reason.
/// Only counts and the app's name are kept, never window titles.
struct WorkspaceSkip: Codable, Equatable, Sendable {
    var bundleID: String; var appName: String; var reason: WorkspaceSkipReason; var count: Int
    init(bundleID: String, appName: String = "", reason: WorkspaceSkipReason, count: Int = 1) {
        self.bundleID = bundleID; self.appName = appName; self.reason = reason; self.count = count
    }

    private static func windows(_ count: Int) -> String { count == 1 ? "1 window" : "\(count) windows" }

    /// Plain-language lines for the preview, sorted so the text is stable.
    static func lines(_ skips: [WorkspaceSkip], availableBundleIDs: Set<String> = [], extraNotes: [String: String] = [:], preview: Bool = false) -> [String] {
        let order = WorkspaceSkipReason.allCases
        // A capture is a census, not an event stream. Repeated entries for the
        // same app/reason describe the same windows, so keep the largest count.
        var census: [String: WorkspaceSkip] = [:]
        for skip in skips where skip.count > 0 {
            let key = skip.bundleID + "|" + skip.reason.rawValue
            if skip.count > (census[key]?.count ?? 0) { census[key] = skip }
        }
        let sorted = census.values.sorted {
            let a = $0.appName.isEmpty ? $0.bundleID : $0.appName, b = $1.appName.isEmpty ? $1.bundleID : $1.appName
            if a != b { return a.localizedCaseInsensitiveCompare(b) == .orderedAscending }
            return order.firstIndex(of: $0.reason)! < order.firstIndex(of: $1.reason)!
        }
        let appLines = sorted.map { skip in
            let name = skip.appName.isEmpty ? "An app" : skip.appName
            switch skip.reason {
            case .slowToRespond: return "\(name) \(preview ? "is" : "was") too slow to answer — try again."
            case .otherSpace:
                if skip.count > 1 || availableBundleIDs.contains(skip.bundleID) {
                    return "\(skip.count) \(name) \(skip.count == 1 ? "window is" : "windows are") on another desktop, so \(preview ? (skip.count == 1 ? "it won't move" : "they won't move") : (skip.count == 1 ? "it wasn't moved" : "they weren't moved")). Switch to that desktop and run this again."
                }
                return "\(name) is on another desktop, so \(preview ? "it won't move" : "it wasn't moved"). Switch to that desktop and run this again."
            case .fullScreen: return "\(preview ? "Will skip" : "Skipped") \(skip.count == 1 ? "1 full-screen" : "\(skip.count) full-screen") \(name) \(skip.count == 1 ? "window" : "windows")."
            case .unreadable: return "\(preview ? "Will skip" : "Skipped") \(skip.count == 1 ? "1" : "\(skip.count)") \(name) \(skip.count == 1 ? "window" : "windows") Dictator \(preview ? "can't" : "couldn't") read."
            case .minimized: return "\(preview ? "Will skip" : "Skipped") \(skip.count == 1 ? "1 minimized" : "\(skip.count) minimized") \(name) \(skip.count == 1 ? "window" : "windows")."
            case .fixedPosition: return "\(preview ? "Will skip" : "Skipped") \(skip.count) \(name) \(skip.count == 1 ? "window that can't be moved" : "windows that can't be moved")."
            case .fixedSize: return "\(preview ? "Will skip" : "Skipped") \(skip.count) \(name) \(skip.count == 1 ? "window that can't be resized" : "windows that can't be resized")."
            }
        }
        var ids: [String] = []
        var grouped: [String: [String]] = [:]
        for (skip, line) in zip(sorted, appLines) {
            if grouped[skip.bundleID] == nil { ids.append(skip.bundleID) }
            grouped[skip.bundleID, default: []].append(line)
        }
        for id in extraNotes.keys.sorted() {
            if grouped[id] == nil { ids.append(id) }
            grouped[id, default: []].append(extraNotes[id]!)
        }
        return ids.map { grouped[$0]!.joined(separator: " ") }
    }

    /// One short paragraph for the result notice, or nil when nothing was skipped.
    static func summary(_ skips: [WorkspaceSkip]) -> String? {
        let lines = lines(skips)
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }
}

/// Public window-server facts, in front-to-back order. Never window names.
struct WorkspaceCGWindow: Equatable, Sendable {
    var pid: Int32; var layer: Int; var width: Double; var height: Double
    var x: Double = 0; var y: Double = 0; var windowID: String = ""
    init(pid: Int32, layer: Int, width: Double, height: Double, x: Double = 0, y: Double = 0, windowID: String = "") {
        self.pid = pid; self.layer = layer; self.width = width; self.height = height
        self.x = x; self.y = y; self.windowID = windowID
    }
    var frame: WorkspaceRect { .init(x: x, y: y, width: width, height: height) }
}

struct WorkspaceStackWindow: Equatable, Sendable {
    var id: String
    var bundleID: String
    var frame: WorkspaceRect
}

enum WorkspaceWindowStack {
    /// AX candidates arrive in kAXWindows order, focused first. Consume each
    /// layer-zero match once so equal bounds in one app have a stable order.
    static func positions(candidates: [(id: String, pid: Int32, frame: WorkspaceRect)],
                          frontToBack: [WorkspaceCGWindow]) -> [String: Int] {
        func rounded(_ r: WorkspaceRect) -> [Double] { [r.x, r.y, r.width, r.height].map { $0.rounded() } }
        var used = Set<Int>(), result: [String: Int] = [:]
        for candidate in candidates {
            if let index = frontToBack.indices.first(where: {
                !used.contains($0) && frontToBack[$0].layer == 0 && frontToBack[$0].pid == candidate.pid
                    && rounded(frontToBack[$0].frame) == rounded(candidate.frame)
            }) {
                used.insert(index); result[candidate.id] = index
            }
        }
        return result
    }

    static func overlaps(_ a: WorkspaceRect, _ b: WorkspaceRect) -> Bool {
        a.isUsable && b.isUsable && min(a.x + a.width, b.x + b.width) > max(a.x, b.x)
            && min(a.y + a.height, b.y + b.height) > max(a.y, b.y)
    }

    /// Live order contains layer-zero, on-screen windows only, including apps
    /// outside the routine. Absent wanted windows (other desktops) do no work.
    static func lifts(wanted: [String], frontToBack: [WorkspaceStackWindow], ignoring: Set<String>) -> [String] {
        var rank: [String: Int] = [:]
        for (index, id) in wanted.enumerated() { rank[id] = index }
        var seen = Set<String>()
        return wanted.reversed().filter { seen.insert($0).inserted }.reversed().filter { id in
            guard !ignoring.contains(id), let index = frontToBack.firstIndex(where: { $0.id == id }) else { return false }
            let window = frontToBack[index]
            return frontToBack[..<index].contains { above in
                !ignoring.contains(above.id) && overlaps(above.frame, window.frame)
                    && (rank[above.id].map { $0 <= rank[id]! } ?? true)
            }
        }
    }

    static func shouldRestoreFocus(previousBundleID: String?, dictatorBundleID: String,
                                   frontToBack: [WorkspaceStackWindow], lifted: Set<String>) -> Bool {
        guard let previousBundleID else { return false }
        if previousBundleID == dictatorBundleID { return true }
        let liftedWindows = frontToBack.filter { lifted.contains($0.id) }
        return !frontToBack.contains { window in
            window.bundleID == previousBundleID && liftedWindows.contains { overlaps(window.frame, $0.frame) }
        }
    }
}

/// Gathers skips per app and reason. A slow app is reported once however many reads timed out.
struct WorkspaceSkipCollector {
    private var byKey: [String: WorkspaceSkip] = [:]
    mutating func add(bundleID: String, appName: String, reason: WorkspaceSkipReason, count: Int = 1) {
        guard count > 0 else { return }
        let key = bundleID + "|" + reason.rawValue
        if reason == .slowToRespond {
            byKey[key] = WorkspaceSkip(bundleID: bundleID, appName: appName, reason: reason, count: 1)
        } else {
            byKey[key, default: WorkspaceSkip(bundleID: bundleID, appName: appName, reason: reason, count: 0)].count += count
        }
    }
    var skips: [WorkspaceSkip] { byKey.values.sorted { ($0.bundleID, $0.reason.rawValue) < ($1.bundleID, $1.reason.rawValue) } }
}

/// What Accessibility says about one window: role, subrole and size only, never its title.
struct WorkspaceAXWindowFacts: Equatable, Sendable {
    var role: String?; var subrole: String?; var width: Double; var height: Double
    init(role: String?, subrole: String?, width: Double, height: Double) { self.role = role; self.subrole = subrole; self.width = width; self.height = height }
}

enum WorkspaceSkipDetector {
    /// Accessibility lists helper elements (a desktop surface, palettes) beside real windows.
    /// Only ordinary windows are comparable with the window-server count.
    /// A missing role or size is unresolved, never "not a window". A missing subrole is fine:
    /// some Java, Electron and older apps do not report one.
    static func isResolved(_ facts: WorkspaceAXWindowFacts) -> Bool {
        facts.role != nil && facts.width > 0 && facts.height > 0
    }

    enum FactsOutcome: Equatable { case complete, slow, unresolved }
    struct FactsResult {
        var facts: [WorkspaceAXWindowFacts]; var outcome: FactsOutcome; var unresolvedCount = 0
        /// Every element read, in order, resolved or not. Reporting and arranging both decide from these.
        var records: [WorkspaceAXWindowFacts] = []
        var complete: Bool { outcome == .complete }
    }

    static func isOrdinaryAXWindow(_ facts: WorkspaceAXWindowFacts) -> Bool {
        facts.role == "AXWindow" && (facts.subrole == nil || ["AXStandardWindow", "AXDialog", "AXSystemDialog"].contains(facts.subrole!))
            && facts.width >= 50 && facts.height >= 50
    }

    /// The one rule for what a reset may arrange; it is a subset of what is counted (dialogs are counted, not arranged).
    static func isArrangeEligible(_ facts: WorkspaceAXWindowFacts) -> Bool {
        isOrdinaryAXWindow(facts) && (facts.subrole == nil || facts.subrole == "AXStandardWindow")
    }

    /// A tile needs both attributes; explain an ineligible standard window
    /// rather than silently dropping its app from the preview.
    static func geometrySkipReason(positionSettable: Bool, sizeSettable: Bool) -> WorkspaceSkipReason? {
        if !positionSettable { return .fixedPosition }
        if !sizeSettable { return .fixedSize }
        return nil
    }
    /// Reads window facts under a deadline and an element budget. Any timeout, an
    /// expired deadline or too many elements makes the result incomplete, and an
    /// incomplete result must not be used to claim windows on another desktop.
    static func gatherFacts(count: Int, maxElements: Int, deadlineReached: () -> Bool,
                            read: (Int) -> (facts: WorkspaceAXWindowFacts, timedOut: Bool)) -> FactsResult {
        guard count <= maxElements else { return FactsResult(facts: [], outcome: .slow) }
        var facts: [WorkspaceAXWindowFacts] = [], records: [WorkspaceAXWindowFacts] = []
        var unresolved = 0
        for index in 0..<count {
            if deadlineReached() { return FactsResult(facts: facts, outcome: .slow, unresolvedCount: unresolved, records: records) }
            let result = read(index)
            if result.timedOut { return FactsResult(facts: facts, outcome: .slow, unresolvedCount: unresolved, records: records) }
            records.append(result.facts)
            // An unreadable fact must not turn an arranged window into "on another desktop".
            if !isResolved(result.facts) { unresolved += 1; continue }
            facts.append(result.facts)
        }
        return FactsResult(facts: facts, outcome: unresolved == 0 ? .complete : .unresolved,
                           unresolvedCount: unresolved, records: records)
    }
    static func ordinaryAXCount(_ windows: [WorkspaceAXWindowFacts]) -> Int { windows.filter(isOrdinaryAXWindow).count }

    /// Ordinary windows (layer 0, not tiny helper surfaces) per process, across every desktop.
    static func layerZeroCounts(_ windows: [WorkspaceCGWindow]) -> [Int32: Int] {
        windows.reduce(into: [:]) { counts, window in
            if window.layer == 0, window.width >= 50, window.height >= 50 { counts[window.pid, default: 0] += 1 }
        }
    }

    /// Accessibility lists only windows on the current desktop, so any ordinary
    /// window beyond that count lives on another desktop.
    static func otherSpaceCount(allDesktopsCount: Int, accessibilityCount: Int) -> Int { max(0, allDesktopsCount - accessibilityCount) }
}

// MARK: - Screen resolution

struct WorkspaceDisplayResolution: Equatable { var display: WorkspaceDisplay?; var note: String? }

enum WorkspaceDisplayResolver {
    static func label(_ choice: WorkspaceDisplayChoice) -> String {
        switch choice {
        case .main: "Main screen"
        case .left: "Left screen"
        case .right: "Right screen"
        case .top: "Top screen"
        case .bottom: "Bottom screen"
        case .largest: "Largest screen"
        case .builtIn: "Built-in screen"
        case .underPointer: "Screen under the pointer"
        }
    }

    static func choice(for target: WorkspaceDisplayTarget) -> WorkspaceDisplayChoice {
        switch target { case .main: .main; case .left: .left; case .right: .right }
    }

    /// The per-Mac override for this Mac, if the routine has one; otherwise the routine's own screen.
    static func resolve(action: WorkspaceAction, macID: String?, displays: [WorkspaceDisplay], pointer: WorkspacePoint?, preview: Bool = false) -> WorkspaceDisplayResolution {
        let choice = macID.flatMap { action.displayOverrides?[$0] } ?? choice(for: action.display)
        return resolve(choice, displays: displays, pointer: pointer, preview: preview)
    }

    static func resolve(_ choice: WorkspaceDisplayChoice, displays: [WorkspaceDisplay], pointer: WorkspacePoint?, preview: Bool = false) -> WorkspaceDisplayResolution {
        let usable = displays.filter { $0.visibleFrame.isUsable }.sorted { $0.id < $1.id }
        guard let main = usable.first(where: \.isMain) ?? usable.first else {
            return WorkspaceDisplayResolution(display: nil, note: preview ? "Dictator can't find a screen to use, so it will skip this step." : "Dictator found no screen to use, so it skipped this step.")
        }
        let name = label(choice)
        func fallback(_ reason: String) -> WorkspaceDisplayResolution {
            WorkspaceDisplayResolution(display: main, note: "\(reason), so ‘\(name)’ \(preview ? "will use" : "used") the main screen.")
        }
        func directional(horizontal: Bool, pickLast: Bool) -> WorkspaceDisplayResolution {
            guard usable.count > 1 else {
                return WorkspaceDisplayResolution(display: main, note: "This Mac has one screen, so ‘\(name)’ \(preview ? "will use" : "used") it.")
            }
            func range(_ r: WorkspaceRect) -> (Double, Double) { horizontal ? (r.x, r.x + r.width) : (r.y, r.y + r.height) }
            func centre(_ d: WorkspaceDisplay) -> Double { let r = range(d.visibleFrame); return (r.0 + r.1) / 2 }
            let ordered = usable.sorted { centre($0) != centre($1) ? centre($0) < centre($1) : $0.id < $1.id }
            let first = ordered.first!, last = ordered.last!
            // Screens that overlap along this axis are stacked the other way.
            let a = range(first.visibleFrame), b = range(last.visibleFrame)
            let overlap = min(a.1, b.1) - max(a.0, b.0)
            if overlap > 0.5 * min(a.1 - a.0, b.1 - b.0) {
                return fallback(horizontal ? "These screens are stacked" : "These screens are side by side")
            }
            // Screens level with each other at the edge (one stacked above the
            // main screen, say): the main screen wins over id order.
            let edge = pickLast ? last : first
            let tied = usable.filter { centre($0) == centre(edge) }
            return WorkspaceDisplayResolution(display: tied.first(where: \.isMain) ?? edge, note: nil)
        }
        switch choice {
        case .main: return WorkspaceDisplayResolution(display: main, note: nil)
        case .left: return directional(horizontal: true, pickLast: false)
        case .right: return directional(horizontal: true, pickLast: true)
        case .top: return directional(horizontal: false, pickLast: false)
        case .bottom: return directional(horizontal: false, pickLast: true)
        case .largest:
            let best = usable.max { l, r in
                let la = l.visibleFrame.width * l.visibleFrame.height, ra = r.visibleFrame.width * r.visibleFrame.height
                if la != ra { return la < ra }
                return l.isMain ? false : r.isMain
            }
            return WorkspaceDisplayResolution(display: best ?? main, note: nil)
        case .builtIn:
            guard let builtIn = usable.first(where: { $0.isBuiltIn == true }) else { return fallback(preview ? "No built-in screen is available" : "No built-in screen was found") }
            return WorkspaceDisplayResolution(display: builtIn, note: nil)
        case .underPointer:
            guard let pointer else { return fallback(preview ? "The pointer position is not available" : "The pointer position was not available") }
            func distance(_ d: WorkspaceDisplay) -> Double {
                let r = d.visibleFrame
                let dx = max(r.x - pointer.x, 0, pointer.x - (r.x + r.width)), dy = max(r.y - pointer.y, 0, pointer.y - (r.y + r.height))
                return (dx * dx + dy * dy).squareRoot()
            }
            let nearest = usable.min { distance($0) != distance($1) ? distance($0) < distance($1) : $0.id < $1.id }
            return WorkspaceDisplayResolution(display: nearest ?? main, note: nil)
        }
    }
}

/// A stable, anonymous name for this Mac, used as the key for per-Mac screen
/// choices. It is a short hash, so the hardware identifier never leaves the Mac.
enum WorkspaceMacIdentity {
    static let current: String = key(forHardware: hardwareUUID() ?? Host.current().localizedName ?? "this-mac")

    static func key(forSetupID id: String) -> String { key(forHardware: "workspace-setup:" + id) }

    static func key(forHardware value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8))
        return "mac-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    private static func hardwareUUID() -> String? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        return IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String
    }
}

// MARK: - Keyboard shortcuts

enum WorkspaceHotkeyFormat {
    /// Standard macOS order: Control, Option, Shift, Command.
    static func modifierGlyphs(_ modifiers: UInt32) -> String {
        (modifiers & WorkspaceHotkey.control != 0 ? "⌃" : "") + (modifiers & WorkspaceHotkey.option != 0 ? "⌥" : "")
            + (modifiers & WorkspaceHotkey.shift != 0 ? "⇧" : "") + (modifiers & WorkspaceHotkey.command != 0 ? "⌘" : "")
    }

    /// Names for keys that do not print a character, plus a US-layout fallback.
    static func staticKeyName(_ keyCode: UInt32) -> String {
        let table: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E",
            15: "R", 16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6", 23: "5", 24: "=", 25: "9", 26: "7", 27: "-",
            28: "8", 29: "0", 30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L", 38: "J", 39: "'", 40: "K", 41: ";",
            42: "\\", 43: ",", 44: "/", 45: "N", 46: "M", 47: ".", 50: "`",
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Esc", 71: "Clear", 76: "Enter",
            65: "Keypad .", 67: "Keypad *", 69: "Keypad +", 75: "Keypad /", 78: "Keypad -", 81: "Keypad =",
            82: "Keypad 0", 83: "Keypad 1", 84: "Keypad 2", 85: "Keypad 3", 86: "Keypad 4", 87: "Keypad 5",
            88: "Keypad 6", 89: "Keypad 7", 91: "Keypad 8", 92: "Keypad 9",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
            114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete", 119: "End", 121: "Page Down",
            123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return table[keyCode] ?? "Code \(keyCode)"
    }

    private static let layoutIndependent: Set<UInt32> = Set<UInt32>([36, 48, 49, 51, 53, 71, 76]).union(64...126)

    /// The key's name on the current keyboard layout (a layout that can type
    /// Latin letters, as macOS menus use), falling back to the US table.
    static func keyName(_ keyCode: UInt32) -> String {
        if !layoutIndependent.contains(keyCode), let name = layoutName(keyCode) { return name }
        return staticKeyName(keyCode)
    }

    static func display(_ hotkey: WorkspaceHotkey, keyName name: (UInt32) -> String = WorkspaceHotkeyFormat.keyName) -> String {
        modifierGlyphs(hotkey.modifiers) + name(hotkey.keyCode)
    }

    private static func layoutName(_ keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(base.assumingMemoryBound(to: UCKeyboardLayout.self), UInt16(keyCode), UInt16(kUCKeyActionDisplay), 0,
                                  UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length).uppercased()
        return text.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value != 127 }) ? text : nil
    }
}

/// Plain-language problems with a proposed shortcut, decided without touching the system.
enum WorkspaceHotkeyConflict {
    static let forceQuitMessage = "Command-Option-Escape is reserved for Force Quit"
    static let reservedByMac: [(keyCode: UInt32, modifiers: UInt32, what: String)] = [
        (12, WorkspaceHotkey.control | WorkspaceHotkey.command, "⌃⌘Q locks your screen"),
        (49, WorkspaceHotkey.control | WorkspaceHotkey.command, "⌃⌘Space opens the emoji picker"),
        (3, WorkspaceHotkey.control | WorkspaceHotkey.command, "⌃⌘F makes a window full screen"),
        (2, WorkspaceHotkey.option | WorkspaceHotkey.command, "⌥⌘D shows and hides the Dock"),
    ]
    /// Modifier keys that can be the dictation key, with the modifier each one is part of.
    static let modifierKeys: [Int: UInt32] = [54: WorkspaceHotkey.command, 55: WorkspaceHotkey.command, 56: WorkspaceHotkey.shift,
        58: WorkspaceHotkey.option, 59: WorkspaceHotkey.control, 60: WorkspaceHotkey.shift, 61: WorkspaceHotkey.option, 62: WorkspaceHotkey.control]

    /// Returns why `key` cannot be used for the routine `routineID`, or nil when it is fine.
    static func problem(for key: WorkspaceHotkey, routineID: String?, routines: [WorkspaceRoutine], triggers: HotkeyTriggers) -> String? {
        let dictation = dictationMessage
        for trigger in [triggers.dictation, triggers.commands] {
            if trigger.keyCodes == [CGKeyCode(key.keyCode)] || trigger.hotkey == key { return dictation }
            // A trigger that is one modifier (such as Right ⌥) would also fire from a shortcut made of just that modifier.
            if trigger.keyCodes.count == 1, let modifier = modifierKeys[Int(trigger.primary)], key.modifiers == modifier { return dictation }
        }
        if (54...63).contains(key.keyCode) { return "Press a regular key together with the modifier keys." }
        if key.keyCode == 53, key.modifiers & (WorkspaceHotkey.command | WorkspaceHotkey.option) == WorkspaceHotkey.command | WorkspaceHotkey.option {
            return forceQuitMessage
        }
        if !key.isValid { return "Hold at least two of ⌃ ⌥ ⌘ while you press the key, so it does not clash with typing." }
        if let reserved = reservedByMac.first(where: { $0.keyCode == key.keyCode && $0.modifiers == key.modifiers }) {
            return "macOS already uses this shortcut (\(reserved.what))."
        }
        if let other = routines.first(where: { $0.id != routineID && $0.hotkey == key }) {
            let name = other.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? "Another routine" : "“\(name)”") already uses this shortcut."
        }
        return nil
    }

    static let dictationMessage = "That key starts dictation. Choose a different shortcut."
    static let dictationPartMessage = "Your dictation key is part of this shortcut. Use the other side's modifier key instead."

    /// A lone modifier press (no regular key yet) is refused only when it is a whole trigger.
    static func modifierOnlyProblem(keyCode: UInt32, triggers: HotkeyTriggers) -> String? {
        guard (54...63).contains(keyCode) else { return nil }
        let code = [CGKeyCode(keyCode)]
        return triggers.dictation.keyCodes == code || triggers.commands.keyCodes == code ? dictationMessage : nil
    }

    /// True when the modifiers of a trigger (for example Right ⌥) are held, judged from the device-level flag bits.
    static func dictationModifierHeld(triggers: HotkeyTriggers, deviceFlags: UInt) -> Bool {
        // fn has no device bit of its own here, so it never counts as held.
        func held(_ code: CGKeyCode) -> Bool { code != 63 && deviceFlags & UInt(DictationKey(keyCode: code).deviceFlag.rawValue) != 0 }
        return [triggers.dictation, triggers.commands].contains { trigger in
            trigger.isModifierOnly && trigger.keyCodes.allSatisfy(held)
        }
    }

    /// Plain words for a failed Carbon registration.
    static func registrationMessage(status: OSStatus) -> String {
        switch status {
        case OSStatus(eventHotKeyExistsErr): "Another app already uses this shortcut"
        case OSStatus(eventHotKeyInvalidErr): "macOS does not accept this shortcut"
        default: "macOS couldn't turn on this shortcut"
        }
    }
}

// MARK: - Plain words for the Workspace launch page

/// Ready-made routines the page offers as a starting point. Each opens in the
/// editor already filled in, so the only thing left is choosing apps.
enum WorkspaceStarter: String, CaseIterable, Identifiable {
    case sideBySide, grid, centerWindow, hideIdle
    var id: String { rawValue }

    var title: String {
        switch self {
        case .sideBySide: "Side by side"
        case .grid: "Four corners"
        case .centerWindow: "Center my window"
        case .hideIdle: "Hide what I'm not using"
        }
    }

    var detail: String {
        switch self {
        case .sideBySide: "Two apps, each on half of the screen."
        case .grid: "Up to four apps, one in each corner."
        case .centerWindow: "Puts the window you're using in the middle of the screen."
        case .hideIdle: BrandVoice.hideIdle
        }
    }

    func routine() -> WorkspaceRoutine {
        let action: WorkspaceAction
        switch self {
        case .sideBySide: action = WorkspaceAction(kind: .arrangeWindows, layout: .halves)
        case .grid: action = WorkspaceAction(kind: .arrangeWindows, layout: .quarters)
        case .centerWindow: action = WorkspaceAction(kind: .centerLastWindow)
        case .hideIdle: action = WorkspaceAction(kind: .hideIdleApps, idleMinutes: 60)
        }
        return WorkspaceRoutine(name: title, actions: [action])
    }
}

enum WorkspaceWords {
    /// "Safari", "Safari and Mail", "Safari, Mail and Notes".
    static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }

    static func duration(minutes: Int) -> String {
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour" : "\(minutes / 60) hours" }
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    static func layout(_ layout: WorkspaceLayout) -> String {
        switch layout {
        case .quarters: "in quarters"
        case .halves: "in halves"
        case .columns: "in columns"
        }
    }

    /// The screen an action uses on this Mac, lower-case for the middle of a sentence.
    static func screen(for action: WorkspaceAction, macID: String?) -> String {
        let choice = macID.flatMap { action.displayOverrides?[$0] } ?? WorkspaceDisplayResolver.choice(for: action.display)
        return "the " + WorkspaceDisplayResolver.label(choice).prefix(1).lowercased() + WorkspaceDisplayResolver.label(choice).dropFirst()
    }

    /// One plain sentence for a step, such as "Arrange Safari and Mail in halves on the main screen".
    static func describe(_ action: WorkspaceAction, macID: String?, appName: (String) -> String) -> String {
        let apps = list(action.bundleIDs.map(appName))
        switch action.kind {
        case .arrangeWindows where action.tabSets != nil:
            return "Open tabs: " + WorkspaceTabWords.summary(action.tabSets ?? [])
        case .arrangeWindows where action.placements != nil:
            let placements = action.placements ?? []
            return placements.isEmpty ? "Place apps (none chosen yet)" : "Place " + placements.map {
                "\($0.appName) on \($0.macName), \($0.monitor.label), \($0.position.label)"
            }.joined(separator: "; ")
        case .arrangeWindows where action.remembered != nil:
            let layouts = (action.remembered ?? [:]).values.sorted { $0.macName.localizedCaseInsensitiveCompare($1.macName) == .orderedAscending }
            let count = layouts.reduce(0) { $0 + $1.windows.count }
            return "Put \(count == 1 ? "1 window" : "\(count) windows") back where they were on \(list(layouts.map(\.macName)))"
        case .arrangeWindows:
            return "Arrange \(apps.isEmpty ? "windows (no apps chosen yet)" : apps) \(layout(action.layout)) on \(screen(for: action, macID: macID))"
        case .centerLastWindow:
            return "Center the window you're using on \(screen(for: action, macID: macID))"
        case .hideIdleApps:
            return "Hide \(apps.isEmpty ? "apps (none chosen yet)" : apps) after \(duration(minutes: action.idleMinutes)) without use"
        }
    }

    static func describe(_ routine: WorkspaceRoutine, macID: String?, appName: (String) -> String) -> String {
        let steps = routine.actions.enumerated().map { index, action in
            let sentence = describe(action, macID: macID, appName: appName)
            return index == 0 ? sentence : sentence.prefix(1).lowercased() + sentence.dropFirst()
        }.joined(separator: ", then ")
        return steps + (routine.showOnly == true ? ", then hide other apps" : "")
    }

    static func summary(_ routine: WorkspaceRoutine, macID: String?, appName: (String) -> String) -> String {
        describe(routine, macID: macID, appName: appName) + "."
    }

    /// What a routine still needs before it can be saved, in words
    /// ("a name", "apps for step 1"). Empty when it can be saved.
    static func missing(_ routine: WorkspaceRoutine) -> [String] {
        var missing: [String] = []
        if routine.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { missing.append("a name") }
        if routine.actions.isEmpty { missing.append("a step") }
        for (index, action) in routine.actions.enumerated()
        where (action.kind == .arrangeWindows || action.kind == .hideIdleApps) && !action.isTabStep && action.bundleIDs.isEmpty {
            missing.append(routine.actions.count == 1 ? "the apps to use" : "the apps for step \(index + 1)")
        }
        return missing
    }

    /// Where a window lands, in words: "left half", "top-right quarter", "column 2 of 3".
    static func placement(_ frame: WorkspaceRect, on screen: WorkspaceRect) -> String {
        guard frame.isUsable, screen.isUsable else { return "somewhere else" }
        let w = frame.width / screen.width, h = frame.height / screen.height
        let cx = (frame.x + frame.width / 2 - screen.x) / screen.width
        let cy = (frame.y + frame.height / 2 - screen.y) / screen.height
        func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.03 }
        let side = cx < 0.5 ? "left" : "right", level = cy < 0.5 ? "top" : "bottom"
        if near(w, 1), near(h, 1) { return "full screen" }
        if near(w, 0.5), near(h, 1) { return "\(side) half" }
        if near(w, 1), near(h, 0.5) { return "\(level) half" }
        if near(w, 0.5), near(h, 0.5) { return "\(level)-\(side) quarter" }
        // A tile of an even grid has edges on the grid lines; a centered window does not.
        let columns = Int(min(max(1, (1 / w).rounded()), 1_000)), rows = Int(min(max(1, (1 / h).rounded()), 1_000))
        let fx = (frame.x - screen.x) / screen.width, fy = (frame.y - screen.y) / screen.height
        if near(w * Double(columns), 1), near(h * Double(rows), 1),
           near(fx, (fx / w).rounded() * w), near(fy, (fy / h).rounded() * h) {
            let column = min(columns, Int(cx * Double(columns)) + 1), row = min(rows, Int(cy * Double(rows)) + 1)
            if rows == 1 { return "column \(column) of \(columns)" }
            if columns == 1 { return "row \(row) of \(rows)" }
            return "row \(row), column \(column)"
        }
        if near(cx, 0.5), near(cy, 0.5) { return "middle" }
        return "part of the screen"
    }

    /// "main screen", or the screen's own name; nil when the Mac has only one screen.
    static func screenName(_ display: WorkspaceDisplay, among displays: [WorkspaceDisplay]) -> String? {
        if displays.count <= 1 { return nil }
        if display.isMain { return "main screen" }
        return display.name.isEmpty ? "other screen" : display.name
    }
}

/// What a preview draws: the screens, where each window will land, and which apps will be hidden.
struct WorkspacePreviewPicture: Equatable {
    struct Tile: Equatable { var appName: String; var frame: WorkspaceRect }
    var screens: [WorkspaceDisplay]
    var tiles: [Tile]
    var hiddenApps: [String]

    static func make(plan: WorkspacePlan, snapshot: WorkspaceSnapshot) -> WorkspacePreviewPicture {
        var order: [String] = [], frames: [String: WorkspaceRect] = [:], hidden: [String] = []
        for operation in plan.operations {
            switch operation {
            case .moveWindow(let id, let frame):
                if frames[id] == nil { order.append(id) }
                frames[id] = frame
            case .hideApp(let bundleID), .hideOtherApp(let bundleID):
                hidden.append(snapshot.applications.first { $0.bundleID == bundleID }?.name ?? bundleID)
            case .focusApp:
                break
            }
        }
        let tiles = order.compactMap { id in
            frames[id].map { frame in
                let window = snapshot.windows.first { $0.id == id }
                let name = window?.appName ?? "App"
                return Tile(appName: name + (window?.isMinimized == true ? " (will come back)" : ""), frame: frame)
            }
        }
        return WorkspacePreviewPicture(screens: snapshot.displays.filter { $0.visibleFrame.isUsable }, tiles: tiles + plan.placementTiles, hiddenApps: hidden)
    }

    /// The screen a frame sits on (the one holding its center), or the main screen.
    func screen(for frame: WorkspaceRect) -> WorkspaceDisplay? {
        let cx = frame.x + frame.width / 2, cy = frame.y + frame.height / 2
        return screens.first { s in
            let r = s.visibleFrame
            return cx >= r.x && cx <= r.x + r.width && cy >= r.y && cy <= r.y + r.height
        } ?? screens.first(where: \.isMain) ?? screens.first
    }

    /// One plain line per change, such as "Safari → left half, main screen".
    var lines: [String] {
        tiles.map { tile in
            guard let screen = screen(for: tile.frame) else { return "\(tile.appName) → moves" }
            let place = WorkspaceWords.placement(tile.frame, on: screen.visibleFrame)
            return "\(tile.appName) → \(place)" + (WorkspaceWords.screenName(screen, among: screens).map { ", \($0)" } ?? "")
        } + hiddenApps.map { "\($0) → hidden (it stays open)" }
    }
}

// MARK: - Remembered layouts

/// Where one window was when a layout was remembered: the app, the screen and
/// its place as fractions of that screen's usable area (so a screen at a new
/// resolution still fits). Never the window's title or contents.
struct WorkspaceSavedWindow: Codable, Equatable, Sendable {
    var bundleID: String
    var appName: String
    var screenID: String
    var place: WorkspaceRect
    var stack: Int? = nil
}

/// One Mac's windows as they were at one moment. Kept in the routine (shared
/// with every Mac), so each Mac can put its own windows back.
struct WorkspaceSavedLayout: Codable, Equatable, Sendable {
    var macName: String
    var capturedAt: Date
    var screens: [WorkspaceDisplay]
    var windows: [WorkspaceSavedWindow]
    /// Browsers on that Mac, sent only with a live capture so the editor can
    /// offer them. Never kept in a saved routine. Optional for older peers.
    var browsers: [WorkspaceBrowserInfo]? = nil
    /// A discovery-only reply can carry browsers even when window capture failed.
    /// Empty windows keep it out of Remember, including through older relays.
    var captureError: String? = nil

    static let maxWindows = 40

    var isValid: Bool {
        !windows.isEmpty && windows.count <= Self.maxWindows && screens.count <= 16 && macName.count <= 120
            && (browsers.map { $0.count <= 20 && $0.allSatisfy(\.isValid) } ?? true)
            && windows.allSatisfy { w in
                !w.bundleID.isEmpty && w.bundleID.count <= 255 && w.appName.count <= 120 && w.screenID.count <= 64
                    && [w.place.x, w.place.y, w.place.width, w.place.height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
                    && w.place.width > 0 && w.place.height > 0
            }
    }

    /// The apps in this layout, in the order their windows were found.
    var bundleIDs: [String] {
        var seen = Set<String>()
        return windows.map(\.bundleID).filter { seen.insert($0).inserted }
    }

    /// Records every open window in `snapshot` (minimized ones are left out),
    /// at most `maxWindows`. Places are rounded to keep the saved routine small.
    static func make(snapshot: WorkspaceSnapshot, macName: String) -> (layout: WorkspaceSavedLayout, notes: [String]) {
        let screens = snapshot.displays.filter { $0.visibleFrame.isUsable }
        var notes: [String] = []
        var windows: [WorkspaceSavedWindow] = []
        func round4(_ v: Double) -> Double { (min(max(v, 0), 1) * 10_000).rounded() / 10_000 }
        for window in snapshot.windows where !window.isMinimized && window.frame.isUsable {
            guard windows.count < maxWindows else { notes.append("Only the first \(maxWindows) windows were remembered."); break }
            let center = (window.frame.x + window.frame.width / 2, window.frame.y + window.frame.height / 2)
            guard let screen = screens.first(where: { $0.id == window.displayID })
                ?? screens.first(where: { s in let r = s.visibleFrame; return center.0 >= r.x && center.0 <= r.x + r.width && center.1 >= r.y && center.1 <= r.y + r.height })
                ?? screens.first(where: \.isMain) ?? screens.first else { continue }
            let r = screen.visibleFrame
            let x = round4((window.frame.x - r.x) / r.width), y = round4((window.frame.y - r.y) / r.height)
            let place = WorkspaceRect(x: x, y: y, width: max(0.0001, min(round4(window.frame.width / r.width), 1 - x)),
                                      height: max(0.0001, min(round4(window.frame.height / r.height), 1 - y)))
            windows.append(WorkspaceSavedWindow(bundleID: window.bundleID, appName: window.appName.isEmpty ? window.bundleID : window.appName,
                                                screenID: screen.id, place: place, stack: window.stack))
        }
        return (WorkspaceSavedLayout(macName: macName, capturedAt: snapshot.capturedAt, screens: screens, windows: windows),
                notes + WorkspaceSkip.lines(snapshot.skipped ?? []))
    }

    /// The layout drawn as it was remembered.
    var picture: WorkspacePreviewPicture {
        let ordered = windows.enumerated().sorted {
            let a = $0.element.stack ?? Int.max, b = $1.element.stack ?? Int.max
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
        let tiles = ordered.compactMap { w -> WorkspacePreviewPicture.Tile? in
            guard let screen = screens.first(where: { $0.id == w.screenID }) else { return nil }
            return .init(appName: w.appName, frame: WorkspaceLayoutRestorer.frame(w.place, on: screen.visibleFrame))
        }
        return WorkspacePreviewPicture(screens: screens, tiles: tiles, hiddenApps: [])
    }

    /// "9 windows in 5 apps".
    var countSummary: String {
        let apps = bundleIDs.count
        return "\(windows.count == 1 ? "1 window" : "\(windows.count) windows") in \(apps == 1 ? "1 app" : "\(apps) apps")"
    }
}

/// Puts a remembered layout back on the screens and windows there are now.
enum WorkspaceLayoutRestorer {
    static func frame(_ place: WorkspaceRect, on screen: WorkspaceRect) -> WorkspaceRect {
        WorkspaceRect(x: screen.x + place.x * screen.width, y: screen.y + place.y * screen.height,
                      width: place.width * screen.width, height: place.height * screen.height)
    }

    /// The screen a remembered screen is now: the same one, else one with the
    /// same name, else the built-in screen for a built-in one, else the main
    /// screen (and a note saying so).
    static func screen(for saved: WorkspaceDisplay, in displays: [WorkspaceDisplay], preview: Bool = false) -> (display: WorkspaceDisplay?, note: String?) {
        let usable = displays.filter { $0.visibleFrame.isUsable }
        if let same = usable.first(where: { $0.id == saved.id && (saved.name.isEmpty || $0.name == saved.name) }) { return (same, nil) }
        if !saved.name.isEmpty, let named = usable.first(where: { $0.name == saved.name }) { return (named, nil) }
        if saved.isBuiltIn == true, let builtIn = usable.first(where: { $0.isBuiltIn == true }) { return (builtIn, nil) }
        let main = usable.first(where: \.isMain) ?? usable.first
        if saved.isMain, let main { return (main, nil) }
        let name = saved.name.isEmpty ? "A screen" : "‘\(saved.name)’"
        return (main, main == nil ? nil : "\(name) isn't connected, so its windows \(preview ? "will go" : "went") to the main screen.")
    }

    /// For each app, its open windows are matched to its remembered windows,
    /// closest in size first. Windows that are not open are reported; extra
    /// open windows are left alone.
    static func plan(_ layout: WorkspaceSavedLayout, snapshot: WorkspaceSnapshot, openingIDs: Set<String> = [], openMissingApps: Bool = false, preview: Bool = false) -> (moves: [(String, WorkspaceRect)], windowStack: [String], notes: [String]) {
        var notes: [String] = []
        var screenFor: [String: WorkspaceDisplay] = [:]
        for saved in layout.screens {
            let resolved = screen(for: saved, in: snapshot.displays, preview: preview)
            if let display = resolved.display { screenFor[saved.id] = display }
            if let note = resolved.note, !notes.contains(note) { notes.append(note) }
        }
        var moves: [(String, WorkspaceRect)] = []
        var stacked: [(id: String, stack: Int)] = []
        for bundleID in layout.bundleIDs {
            let saved = layout.windows.filter { $0.bundleID == bundleID }
            let name = saved.first?.appName ?? bundleID
            let open = snapshot.windows.filter { $0.bundleID == bundleID && !$0.isMinimized && $0.frame.isUsable }
            if open.isEmpty {
                if openingIDs.contains(bundleID) { continue }
                if let note = unavailableNote(bundleID: bundleID, name: name, snapshot: snapshot, openMissingApps: openMissingApps, preview: preview) { notes.append(note) }
                continue
            }
            let targets = saved.map { w -> WorkspaceRect? in screenFor[w.screenID].map { frame(w.place, on: $0.visibleFrame) } }
            var pairs: [(cost: Double, saved: Int, window: Int)] = []
            for (i, target) in targets.enumerated() {
                guard let t = target, t.isUsable else { continue }
                for (j, window) in open.enumerated() {
                    let f = window.frame
                    let cost = abs(t.width - f.width) + abs(t.height - f.height) + 0.25 * (abs(t.x - f.x) + abs(t.y - f.y))
                    pairs.append((cost, i, j))
                }
            }
            pairs.sort { ($0.cost, $0.saved, $0.window) < ($1.cost, $1.saved, $1.window) }
            var usedSaved = Set<Int>(), usedWindow = Set<Int>(), chosen: [(Int, Int)] = []
            for pair in pairs where !usedSaved.contains(pair.saved) && !usedWindow.contains(pair.window) {
                usedSaved.insert(pair.saved); usedWindow.insert(pair.window); chosen.append((pair.saved, pair.window))
            }
            for (i, j) in chosen.sorted(by: { $0.0 < $1.0 }) {
                moves.append((open[j].id, targets[i]!))
                if let stack = saved[i].stack { stacked.append((open[j].id, stack)) }
            }
            let missing = saved.count - chosen.count
            if missing > 0, !(snapshot.skipped ?? []).contains(where: { $0.bundleID == bundleID }) {
                notes.append("\(name): \(missing == 1 ? "1 remembered window is" : "\(missing) remembered windows are") unavailable on this desktop.")
            }
        }
        return (moves, stacked.enumerated().sorted {
            $0.element.stack == $1.element.stack ? $0.offset < $1.offset : $0.element.stack > $1.element.stack
        }.map { $0.element.id }, notes)
    }

    static func unavailableNote(bundleID: String, name: String, snapshot: WorkspaceSnapshot, openMissingApps: Bool = false, preview: Bool = false) -> String? {
        if (snapshot.skipped ?? []).contains(where: { $0.bundleID == bundleID && $0.count > 0 }) { return nil }
        if snapshot.windows.contains(where: { $0.bundleID == bundleID }) || snapshot.applications.contains(where: { $0.bundleID == bundleID }) {
            return "\(name) has no available window on this desktop, so \(preview ? "it won't move" : "it wasn't moved")."
        }
        return "\(name) isn't open, so \(preview ? "it won't move" : "it wasn't moved")."
            + (openMissingApps ? "" : " Turn on “Open these apps if they aren't open” to open it.")
    }
}

/// Counts only: safe to relay and log, with no titles or document contents.
struct WorkspaceRunCounts: Codable, Equatable, Sendable {
    var windowsMoved = 0
    var windowsBroughtBack = 0
    var appsOpened = 0
    var windowsMinimized = 0
    var skips: [String: [String: Int]] = [:]
    /// Optional because an older Mac sends reports without it and must still be read.
    var tabsOpened: Int? = nil

    mutating func record(_ skips: [WorkspaceSkip]) {
        for skip in skips where skip.count > 0 {
            self.skips[skip.reason.rawValue, default: [:]][skip.bundleID] = skip.count
        }
    }
    var diagnostic: String {
        let reasons = skips.keys.sorted().map { reason in
            reason + ":" + skips[reason]!.keys.sorted().map { "\($0)=\(skips[reason]![$0]!)" }.joined(separator: ",")
        }.joined(separator: ";")
        let line = "moved=\(windowsMoved) broughtBack=\(windowsBroughtBack) opened=\(appsOpened) minimized=\(windowsMinimized) skips=[\(reasons)]"
        return line + (tabsOpened.map { $0 > 0 ? " tabs=\($0)" : "" } ?? "")
    }
}

/// What a run on another Mac did, in one line, for the Mac that asked.
struct WorkspaceRunReport: Codable, Equatable, Sendable {
    var macName: String
    var summary: String
    /// Optional for older peers; plain failure only, never raw system errors.
    var failure: String? = nil
    var counts: WorkspaceRunCounts? = nil
}

struct WorkspaceRunOutcome {
    var summary: String
    var failure: String? = nil
    var counts: WorkspaceRunCounts? = nil
}

extension WorkspaceAction {
    /// A "put windows back where they were" step for these layouts. `bundleIDs`
    /// lists their apps (at most 100), so an older build still has something to tile.
    static func remembering(_ layouts: [String: WorkspaceSavedLayout], id: String = UUID().uuidString, openMissingApps: Bool? = true) -> WorkspaceAction {
        let layouts = layouts.mapValues { layout in
            var saved = layout
            saved.browsers = nil
            saved.captureError = nil
            return saved
        }
        var seen = Set<String>()
        let apps = layouts.keys.sorted().flatMap { layouts[$0]!.bundleIDs }.filter { seen.insert($0).inserted }
        return WorkspaceAction(id: id, kind: .arrangeWindows, bundleIDs: Array(apps.prefix(100)), remembered: layouts, openMissingApps: openMissingApps)
    }
}

extension WorkspaceRoutine {
    /// A new routine that puts back the windows remembered in `layouts`,
    /// named "My layout", or "My layout 2" and so on when that is taken.
    static func remembering(_ layouts: [String: WorkspaceSavedLayout], existing: [WorkspaceRoutine]) -> WorkspaceRoutine {
        let names = Set(existing.map(\.name))
        let name = (1...).lazy.map { $0 == 1 ? "My layout" : "My layout \($0)" }.first { !names.contains($0) }!
        return WorkspaceRoutine(name: name, actions: [.remembering(layouts)])
    }
}

// MARK: - Which run Undo belongs to

/// The run whose changes this Mac can undo. Every run gets a fresh id, and
/// `fromMac` names the Mac that asked for it (nil when it started here). An
/// Undo asked from another Mac only reverses that Mac's own run of the same
/// routine, never a newer run that has since replaced it on this Mac.
struct WorkspaceRunOrigin: Equatable {
    /// Shared by every Mac a single run reached, so an Undo names exactly
    /// that run.
    var operationID = UUID().uuidString
    var routineID: String
    var routineName: String
    var fromMac: String?

    /// An Undo carrying an operation id matches only that run. Without one
    /// (an older Mac asking), fall back to the same Mac and routine.
    func isUndoable(routineID: String, from mac: String, operationID: String? = nil) -> Bool {
        if let operationID { return self.operationID == operationID }
        return fromMac == mac && self.routineID == routineID
    }
}

// MARK: - What "Hide apps you haven't used" knows

/// Dictator only sees which apps are used while it runs with a hiding routine
/// on. When it starts watching, every open app counts as just used, so nothing
/// can be hidden until the routine's full wait has passed since then.
enum WorkspaceIdleWords {
    /// The earliest moment an app can count as unused for `idleMinutes`.
    static func firstEligible(trackingSince: Date, idleMinutes: Int) -> Date {
        trackingSince.addingTimeInterval(Double(idleMinutes) * 60)
    }

    /// One line for the routine's row.
    static func status(trackingSince: Date?, idleMinutes: Int, now: Date, time: (Date) -> String = time) -> String {
        guard let since = trackingSince else {
            return "Dictator starts noticing which apps you use when this routine is on."
        }
        let eligible = firstEligible(trackingSince: since, idleMinutes: idleMinutes)
        if now < eligible {
            return "Noticing which apps you use since \(time(since)). Use before then isn't known, so nothing is hidden before \(time(eligible))."
        }
        return "Noticing which apps you use since \(time(since)). Apps unused for \(WorkspaceWords.duration(minutes: idleMinutes)) since then can be hidden."
    }

    /// A line for Preview and Run while it is still too early to hide anything; nil once it isn't.
    static func note(trackingSince: Date?, idleMinutes: Int, now: Date, time: (Date) -> String = time) -> String? {
        guard let since = trackingSince else { return nil }
        let eligible = firstEligible(trackingSince: since, idleMinutes: idleMinutes)
        guard now < eligible else { return nil }
        return "No app can be hidden yet: Dictator has only noticed which apps you use since \(time(since)), so the earliest is \(time(eligible))."
    }

    static func time(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(date: .abbreviated, time: .shortened)
    }
}
