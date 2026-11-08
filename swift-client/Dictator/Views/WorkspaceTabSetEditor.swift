import SwiftUI

/// Shared with app placements, including a saved monitor while its Mac is offline.
enum WorkspaceEditorMonitorChoices {
    static func choices(displays: [WorkspaceDisplay], saved: WorkspaceMonitorChoice?) -> [WorkspaceMonitorChoice] {
        var choices = WorkspaceDisplayChoice.allCases.map { WorkspaceMonitorChoice.generic($0) }
        for display in displays {
            if let id = display.stableUUID {
                let choice = WorkspaceMonitorChoice.specific(id: id, name: display.name)
                if !choices.contains(choice) { choices.append(choice) }
            }
        }
        if let saved, !choices.contains(saved) { choices.append(saved) }
        return choices
    }
}

/// Keeps the person's text separate from the addresses saved in a routine.
struct WorkspaceTabSetDraft: Equatable, Identifiable {
    var set: WorkspaceTabSet
    var addressesText: String
    var id: String { self.set.id }

    init(_ set: WorkspaceTabSet) {
        self.set = set
        addressesText = set.urls.joined(separator: "\n")
    }

    var parsed: (addresses: [String], rejected: [String]) { WorkspaceTabAddress.parse(addressesText) }
    var saved: WorkspaceTabSet {
        var result = set
        result.urls = parsed.addresses
        return result
    }

    var problem: String? {
        if !parsed.rejected.isEmpty { return "Use a web address for each line listed below." }
        if parsed.addresses.isEmpty { return "Add at least one web address to this window." }
        if parsed.addresses.count > WorkspaceTabSet.maxTabs { return "Use at most 50 web addresses in each window." }
        if set.browserBundleID.isEmpty { return "Choose a browser for this window." }
        if !saved.isValid { return "Choose a Mac, browser and valid profile for this window." }
        return nil
    }

    static func newWindow(mac: WorkspaceMacOption, browsers: [WorkspaceBrowserInfo]) -> Self {
        let browser = browsers.first
        return Self(WorkspaceTabSet(macID: mac.id, macName: mac.name,
                                    browserBundleID: browser?.bundleID ?? "", browserName: browser?.name ?? ""))
    }

    static func editing(_ sets: [WorkspaceTabSet]) -> [Self] {
        var seen = Set<String>()
        return sets.map { set in
            var draft = Self(set)
            if draft.set.id.isEmpty || !seen.insert(draft.id).inserted {
                repeat { draft.set.id = UUID().uuidString } while !seen.insert(draft.id).inserted
            }
            return draft
        }
    }

    /// Matches `openingTabs`: the compatibility app list always names only the browsers.
    static func action(_ drafts: [Self], id: String = UUID().uuidString) -> WorkspaceAction {
        let sets = drafts.map(\.saved)
        return WorkspaceAction(id: id, kind: .arrangeWindows,
                               bundleIDs: Array(Set(sets.map(\.browserBundleID))).sorted(), tabSets: sets)
    }

    static func problem(_ drafts: [Self]) -> String? {
        guard (1...20).contains(drafts.count) else { return "Use 1–20 windows in each Open tabs step." }
        return drafts.compactMap(\.problem).first
    }

    mutating func chooseMac(_ mac: WorkspaceMacOption, browsers: [WorkspaceBrowserInfo]) {
        if mac.id != set.macID, set.monitor != nil || set.position != nil {
            set.monitor = .generic(.main)
            set.position = set.position ?? .full
        }
        set.macID = mac.id
        set.macName = mac.name
        // A saved browser or profile may be available again when this Mac reconnects.
        if set.browserBundleID.isEmpty, let first = browsers.first { chooseBrowser(first) }
    }

    mutating func chooseBrowser(_ browser: WorkspaceBrowserInfo) {
        guard browser.bundleID != set.browserBundleID else { return }
        set.browserBundleID = browser.bundleID
        set.browserName = browser.name
        set.profile = nil
    }

    mutating func chooseMonitor(_ monitor: WorkspaceMonitorChoice?) {
        set.monitor = monitor
        set.position = monitor == nil ? nil : (set.position ?? .full)
    }

    mutating func choosePosition(_ position: WorkspacePosition) {
        set.monitor = set.monitor ?? .generic(.main)
        set.position = position
    }

    func browserChoices(_ available: [WorkspaceBrowserInfo]) -> [WorkspaceBrowserInfo] {
        guard !set.browserBundleID.isEmpty, !available.contains(where: { $0.bundleID == set.browserBundleID }) else { return available }
        return available + [WorkspaceBrowserInfo(bundleID: set.browserBundleID, name: set.browserName)]
    }

    func profileChoices(_ available: [WorkspaceBrowserProfile]) -> [WorkspaceBrowserProfile] {
        guard let profile = set.profile, !available.contains(where: { $0.directory == profile.directory }) else { return available }
        return available + [profile]
    }

    static func availabilityLabel(_ name: String, available: Bool) -> String {
        name + (available ? "" : " (not available right now)")
    }

    func windowCaption(catalog: [WorkspaceBrowsers.CatalogEntry] = WorkspaceBrowsers.bundledCatalog) -> String? {
        guard !set.browserBundleID.isEmpty,
              !WorkspaceBrowsers.opensItsOwnWindow(bundleID: set.browserBundleID, catalog: catalog) else { return nil }
        return "This browser decides where these pages open, so they may join a window that's already open."
    }
}

struct WorkspaceTabSetEditor: View {
    @Binding var drafts: [WorkspaceTabSetDraft]
    let macs: [WorkspaceMacOption]
    let browsers: [String: [WorkspaceBrowserInfo]]
    var displays: (String, String) -> [WorkspaceDisplay] = { _, _ in [] }

    static let footer = "If this window is still open, running the routine usually brings it back instead of opening another. Undo doesn't close tabs."

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpace.s) {
            ForEach($drafts) { $draft in
                windowCard($draft)
            }
            Button("Add another window") {
                guard let mac = macs.first(where: \.isCurrent) ?? macs.first else { return }
                drafts.append(.newWindow(mac: mac, browsers: browsers[mac.id] ?? []))
            }
            .disabled(drafts.count >= 20)
        }
    }

    private func windowCard(_ draft: Binding<WorkspaceTabSetDraft>) -> some View {
        let value = draft.wrappedValue
        let available = browsers[value.set.macID] ?? []
        let profiles = available.first { $0.bundleID == value.set.browserBundleID }?.profiles ?? []
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            HStack(spacing: DSSpace.xs) {
                Text("Browser window").font(.dsSection)
                Spacer()
                if drafts.count > 1 {
                    Button("Remove window", role: .destructive) { drafts.removeAll { $0.id == value.id } }
                        .buttonStyle(.dsDestructive)
                }
            }
            if macs.count > 1 {
                Picker("Mac", selection: Binding(get: { draft.wrappedValue.set.macID }, set: { id in
                    guard let mac = macs.first(where: { $0.id == id }) else { return }
                    draft.wrappedValue.chooseMac(mac, browsers: browsers[id] ?? [])
                })) {
                    ForEach(macs) { mac in
                        Text(mac.name + (mac.isCurrent ? " (this Mac)" : mac.online ? "" : " (offline)"))
                            .tag(mac.id)
                    }
                    if !macs.contains(where: { $0.id == value.set.macID }) {
                        Text(WorkspaceTabSetDraft.availabilityLabel(value.set.macName, available: false)).tag(value.set.macID)
                    }
                }
            } else {
                Text(value.set.macName + (macs.first?.id == value.set.macID ? " (this Mac)" : " (not available right now)"))
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
            Picker("Browser", selection: Binding(get: { draft.wrappedValue.set.browserBundleID }, set: { id in
                guard let browser = available.first(where: { $0.bundleID == id }) else { return }
                draft.wrappedValue.chooseBrowser(browser)
            })) {
                if value.set.browserBundleID.isEmpty { Text("Choose a browser").tag("") }
                ForEach(value.browserChoices(available)) { browser in
                    Text(WorkspaceTabSetDraft.availabilityLabel(browser.name, available: available.contains { $0.bundleID == browser.bundleID }))
                        .tag(browser.bundleID)
                }
            }
            if let caption = value.windowCaption() {
                Text(caption).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
            if available.isEmpty {
                Text(value.set.browserBundleID.isEmpty ? "No browsers are known for this Mac right now." : "No browsers are available for this Mac right now. Your saved choices are kept.")
                    .font(.dsSecondary).foregroundStyle(Color.dsTextSecondary)
            }
            if !profiles.isEmpty || value.set.profile != nil {
                Picker("Profile", selection: Binding(get: { draft.wrappedValue.set.profile?.directory }, set: { directory in
                    draft.wrappedValue.set.profile = directory.flatMap { selected in value.profileChoices(profiles).first { $0.directory == selected } }
                })) {
                    Text("Whichever was used last").tag(String?.none)
                    ForEach(value.profileChoices(profiles)) { profile in
                        Text(WorkspaceTabSetDraft.availabilityLabel(profile.name, available: profiles.contains { $0.directory == profile.directory }))
                            .tag(String?.some(profile.directory))
                    }
                }
            }
            placementControls(draft)
            Text("Web addresses, one per line").font(.dsBodyMedium)
            TextEditor(text: draft.addressesText)
                .font(.dsBody).frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(DSSpace.xxs).background(Color.dsSurfaceSunken, in: RoundedRectangle(cornerRadius: DSRadius.control))
                .overlay(RoundedRectangle(cornerRadius: DSRadius.control).strokeBorder(Color.dsBorderSubtle, lineWidth: 1))
                .accessibilityLabel("Web addresses, one per line")
            if let problem = value.problem {
                Text(problem).font(.dsSecondary).foregroundStyle(Color.dsWarning)
            }
            if !value.parsed.rejected.isEmpty {
                Text("These lines aren't web addresses:").font(.dsSecondary).foregroundStyle(Color.dsWarning)
                ForEach(Array(value.parsed.rejected.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.dsSecondary).foregroundStyle(Color.dsTextSecondary).textSelection(.enabled)
                }
            }
        }
        .padding(DSSpace.m)
        .dsCardSurface()
    }

    private func placementControls(_ draft: Binding<WorkspaceTabSetDraft>) -> some View {
        let value = draft.wrappedValue
        let monitors = WorkspaceEditorMonitorChoices.choices(
            displays: displays(value.set.macID, value.set.macName), saved: value.set.monitor)
        return VStack(alignment: .leading, spacing: DSSpace.xs) {
            Text("Where it goes").font(.dsSection)
            Picker("Monitor", selection: Binding(get: { draft.wrappedValue.set.monitor }, set: {
                draft.wrappedValue.chooseMonitor($0)
            })) {
                Text("Wherever the browser puts it").tag(WorkspaceMonitorChoice?.none)
                ForEach(monitors, id: \.self) { monitor in
                    Text(monitor.label).tag(WorkspaceMonitorChoice?.some(monitor))
                }
            }
            Picker("Position", selection: Binding(get: { draft.wrappedValue.set.position ?? .full }, set: {
                draft.wrappedValue.choosePosition($0)
            })) {
                ForEach(WorkspacePosition.allCases, id: \.self) { position in
                    Text(position.label).tag(position)
                }
            }
            .disabled(value.set.monitor == nil)
        }
    }
}
