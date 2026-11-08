import AppKit
import SwiftUI
import SwiftData
import XCTest
@testable import Dictator

/// Renders the Settings pages to PNGs for visual review. Runs only when
/// DICTATOR_SNAPSHOT_DIR is set or /tmp/dictator-settings-snaps exists.
@MainActor
final class SettingsSnapshotTests: XCTestCase {
    private var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["DICTATOR_SNAPSHOT_DIR"] { return URL(fileURLWithPath: path) }
        let fallback = "/tmp/dictator-settings-snaps"
        return FileManager.default.fileExists(atPath: fallback) ? URL(fileURLWithPath: fallback) : nil
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String, scheme: ColorScheme = .dark) async throws {
        guard let directory else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).background(Color.dsBgContent).preferredColorScheme(scheme))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1_200))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    /// The Dictionary with sample words.
    func testRenderDictionary() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Dictator-DictionarySnapshot-\(UUID().uuidString)", isDirectory: true)
        let container = try XCTUnwrap(PersistenceLoader.load(applicationSupport: root).container)
        let repositories = Repositories.make(container: container)
        try await repositories.dictionary.upsert([
            DictionaryEntryDTO(id: UUID(), pattern: "Moptop", replacement: "", isVocabulary: true, isStarred: true, useCount: 41),
            DictionaryEntryDTO(id: UUID(), pattern: "mop top", replacement: "Moptop", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "Dana Levin", replacement: "", isVocabulary: true, useCount: 18),
            DictionaryEntryDTO(id: UUID(), pattern: "GitHub", replacement: "", isVocabulary: true, useCount: 12),
            DictionaryEntryDTO(id: UUID(), pattern: "git hub", replacement: "GitHub", isVocabulary: false),
            DictionaryEntryDTO(id: UUID(), pattern: "Kineret", replacement: "", isVocabulary: true, useCount: 4, origin: "learned"),
        ])
        let hub = RepositoryHub(current: repositories)
        for scheme in [ColorScheme.dark, .light] {
            try await render(DictionaryView().environment(\.repositoryHub, hub), size: CGSize(width: 900, height: 820),
                             name: "dictionary-\(scheme == .dark ? "dark" : "light")", scheme: scheme)
        }
    }

    /// The dictation badge and its voice launch mode, side by side.
    func testRenderIndicator() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        for (name, voiceLaunch, countdown) in [("indicator-dictation", false, nil), ("indicator-voice-launch", true, nil), ("indicator-voice-launch-countdown", true, 7)] as [(String, Bool, Int?)] {
            for scheme in [ColorScheme.dark, .light] {
                let model = WalkieTalkieIndicatorModel()
                model.voiceLaunch = voiceLaunch
                model.countdown = countdown
                for _ in 0..<20 { model.push(0.05) }
                let size = WalkieTalkieIndicatorView.size(for: .recording, label: model.hasLabel)
                try await render(WalkieTalkieIndicatorView(model: model), size: CGSize(width: size.width + 20, height: size.height + 20),
                                 name: "\(name)-\(scheme == .dark ? "dark" : "light")", scheme: scheme)
            }
        }
    }

    func testBrandResourcesResolveWithoutSystemFontFallback() throws {
        _ = DSFont.display(30)
        _ = DSFont.body(14)
        XCTAssertNotNil(NSFont(name: "Anton-Regular", size: 30))
        XCTAssertNotNil(NSFont(name: "Jost-Regular", size: 14))
        XCTAssertNotNil(NSImage(named: "BrandDictate"))
        XCTAssertNotNil(NSImage(named: "BrandRays"))
    }

    /// Real Home layout with an in-memory store and synthetic words only.
    func testRenderBrandAppearance() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let schema = Repositories.schema
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let repositories = Repositories.make(container: container)
        let hub = RepositoryHub(current: repositories)
        let settings = AppSettings.shared
        let previousWelcome = settings.didCompleteWelcome
        let previousHistory = settings.persistHistory
        let previousPolicy = settings.cachedSurfacePolicyJSON
        let previousKey = settings.hotkeyKeyCode
        defer {
            settings.didCompleteWelcome = previousWelcome
            settings.persistHistory = previousHistory
            settings.cachedSurfacePolicyJSON = previousPolicy
            settings.hotkeyKeyCode = previousKey
        }
        settings.didCompleteWelcome = true
        settings.persistHistory = true
        settings.hotkeyKeyCode = 61 // Right Option
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save", rules: []))
        for text in ["Send the revised notes tomorrow morning.", "Add the string part on the second verse, and keep the vocal dry.", "The next version is ready for review."] {
            try await repositories.history.record(HistoryRecordDTO(text: text, durationSeconds: 6, inferenceMs: nil, modality: "voice", source: "dictator"))
        }
        for scheme in [ColorScheme.dark, .light] {
            let appearance = scheme == .dark ? "dark" : "light"
            for size in [CGSize(width: 960, height: 640), CGSize(width: 820, height: 560)] {
                try await render(MainWindowView().environment(\.repositoryHub, hub), size: size,
                                 name: "brand-home-\(appearance)-\(Int(size.width))", scheme: scheme)
            }
            try await render(WelcomeView { _ in }, size: CGSize(width: 560, height: 680),
                             name: "brand-welcome-\(appearance)", scheme: scheme)
            try await render(GeneralSettingsPage(), size: CGSize(width: 820, height: 1050),
                             name: "brand-general-\(appearance)", scheme: scheme)
        }
        let ids = try await repositories.history.allEntries().map(\.id)
        try await repositories.history.delete(ids: ids)
        try await render(MainWindowView().environment(\.repositoryHub, hub), size: CGSize(width: 820, height: 560),
                         name: "brand-home-empty")
        settings.hotkeyKeyCode = 54 // Right Command, a longer supported key name.
        try await render(HomeBrandHeader(keys: settings.hotkeyTriggers),
                         size: CGSize(width: 600, height: 160), name: "brand-alternate-key")
    }

    private func snapshot(localId: String, miniOnline: Bool) -> SetupSnapshot {
        let now = Date()
        let machines = [
            SetupSnapshot.Machine(id: "mini", name: "Mac mini", profile: MachineProfile(productName: "Mac mini (2024)", memoryGB: 16, tailscaleIP: "100.64.0.1"),
                                  hasMic: false, online: miniOnline, lastSeen: now.addingTimeInterval(-900), isCore: true, localModels: ["gemma4:e2b-it-qat"]),
            SetupSnapshot.Machine(id: localId, name: "MacBook Pro", profile: MachineProfile(productName: "MacBook Pro (14-inch, 2021)", memoryGB: 32, tailscaleIP: "100.64.0.2"),
                                  hasMic: true, online: true, lastSeen: now, isCore: false, localModels: ["gemma3:4b"]),
            SetupSnapshot.Machine(id: "studio", name: "Mac Studio", profile: MachineProfile(productName: "Mac Studio (2023)", memoryGB: 96, tailscaleIP: "100.64.0.3"),
                                  hasMic: true, online: true, lastSeen: now, isCore: false, localModels: nil),
            SetupSnapshot.Machine(id: "imac", name: "iMac", profile: MachineProfile(productName: "iMac (24-inch, M1, 2021)", memoryGB: 8, tailscaleIP: "100.64.0.4"),
                                  hasMic: true, online: true, lastSeen: now, isCore: false, localModels: nil),
        ]
        let speech = SetupSnapshot.SpeechService(address: "http://100.64.0.1:7878", machineId: "mini", reachable: miniOnline,
                                                 speechModel: "mlx-community/whisper-small-mlx", cleanupModel: "gemma4:e2b-it-qat",
                                                 cleanupMachineId: "mini", checkedAt: now)
        let backup = SetupSnapshot.SpeechService(address: "http://100.64.0.3:7878", machineId: "studio", reachable: true,
                                                 speechModel: "whisper-large-v3-turbo", cleanupModel: nil, cleanupMachineId: "studio", checkedAt: now)
        return SetupSnapshot(coreId: "mini", machines: machines, speech: speech, backups: [backup], cleanupOn: true, generatedAt: now)
    }

    func testRenderCleanupStamps() async throws {
        func entry(_ text: String, heard: String, level: String, outcome: String, ms: Int) -> DictationEntryDTO {
            var entry = DictationEntryDTO(id: UUID(), timestamp: Date(), text: text, durationSeconds: 4, inferenceMs: 900, wordCount: 6)
            entry.modality = "voice"
            entry.destinationAppName = "Notes"
            entry.heardText = heard
            entry.cleanupLevel = level
            entry.cleanupOutcome = outcome
            entry.cleanupMs = ms
            entry.polishModel = "gemma4:e2b-it-qat"
            return entry
        }
        let polished = entry("I think we should ship it today.", heard: "so um I think we should we should probably ship it today",
                             level: "strong", outcome: "applied", ms: 900)
        let rows = [polished,
                    entry("So I think we should ship it today.", heard: "so I think we should ship it today", level: "strong", outcome: "fallback", ms: 2100),
                    entry("so um ship it today", heard: "so um ship it today", level: "medium", outcome: "rejected", ms: 800)]
        try await render(VStack(spacing: 0) { ForEach(rows) { HistoryRow(entry: $0) } }, size: CGSize(width: 720, height: 300), name: "history-cleanup-rows")
        try await render(CleanupDetail(entry: polished, stamp: CleanupStamp(polished)!), size: CGSize(width: 340, height: 170), name: "history-cleanup-detail")
    }

    func testRenderSettingsPages() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let viewModel = DictatorViewModel.shared
        let previous = viewModel.setupSnapshot
        defer { if let previous { viewModel.showSetupSnapshot(previous) } }
        let size = CGSize(width: 1000, height: 900)

        viewModel.showSetupSnapshot(snapshot(localId: viewModel.localEdgeId, miniOnline: true))
        try await render(SettingsView(), size: size, name: "0-general")
        try await render(YourMacsSettingsPage(), size: CGSize(width: 1100, height: 1000), name: "1-your-macs")
        try await render(DictationSettingsPage(), size: size, name: "2-dictation")
        try await render(HistoryPrivacySettingsPage(), size: size, name: "3-history")
        try await render(AdvancedSettingsPage(), size: CGSize(width: 1000, height: 1400), name: "4-advanced")
        try await render(AddModelSheet(machine: snapshot(localId: "x", miniOnline: true).machines[2]), size: CGSize(width: 580, height: 560), name: "6-add-model")

        let alerts: [(String, DictationAlert)] = [
            ("9-alert-unreachable", DictationAlert(title: "Can’t reach Mac mini", detail: "Check that it’s on, awake and connected to Tailscale. What you said is kept in History & Privacy, to turn into text later.", action: .macs)),
            ("9-alert-mic", DictationAlert(title: "No microphone found", detail: "Connect a microphone, or check which one is chosen in Settings › General.", action: .general)),
            ("9-alert-clipboard", .clipboardOnly(reason: "x", needsAccessibility: false)),
        ]
        for (name, alert) in alerts {
            try await render(DictationAlertView(alert: alert, onAction: {}, onClose: {}), size: CGSize(width: 440, height: 140), name: name)
        }

        viewModel.showSetupSnapshot(snapshot(localId: viewModel.localEdgeId, miniOnline: false))
        try await render(YourMacsSettingsPage(), size: CGSize(width: 1100, height: 1000), name: "8-your-macs-offline")
    }

    func testRenderFirstUseAndRecovery() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let vm = DictatorViewModel.shared
        let previous = vm.setupSnapshot
        defer { if let previous { vm.showSetupSnapshot(previous) } }
        var unavailable = snapshot(localId: vm.localEdgeId, miniOnline: false)
        unavailable.backups = []
        vm.showSetupSnapshot(unavailable)
        try await render(WelcomeView { _ in }, size: CGSize(width: 560, height: 680), name: "ux-welcome")
        try await render(AddModelSheet(machine: snapshot(localId: "x", miniOnline: true).machines[2], initialJob: .speech),
                         size: CGSize(width: 580, height: 580), name: "ux-speech-setup")
        try await render(YourMacsSettingsPage(), size: CGSize(width: 620, height: 1700), name: "ux-macs-narrow")
        try await render(DictationSettingsPage(), size: CGSize(width: 620, height: 750), name: "ux-dictation-narrow")
        try await render(SettingsView(), size: CGSize(width: 620, height: 560), name: "ux-settings-minimum")
        for busy in [false, true] {
            try await render(RecoveryNoticeCard(count: 3, recordedAt: Date(timeIntervalSince1970: 1_793_150_000),
                                               retentionNote: "Removed at startup after 11 Nov 2026, 09:00, or sooner if recovery storage fills up.",
                                               busy: busy, notice: busy ? nil : "The speech connection failed. Try again when it is available.",
                                               recover: {}, review: {}),
                             size: CGSize(width: 580, height: 280), name: busy ? "ux-recovery-busy" : "ux-recovery")
        }
    }

    /// Voice launch with a few cards on, people and a project. Synthetic names only.
    func testRenderVoiceLaunch() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let settings = AppSettings.shared
        let previous = settings.voiceLaunchJSON
        defer { settings.voiceLaunchJSON = previous }
        var config = VoiceLaunchConfig.empty
        for id in ["youtube", "claude", "email"] { VoiceCards.turnOn(id, in: &config) }
        VoiceCards.setWhatsAppMode(.checkFirst, in: &config)
        VoiceCards.addProjects(["/Users/sample/Projects/Garden"], to: &config)
        VoiceCards.turnOn("claude-code", in: &config)
        _ = VoicePeople.save(PersonDraft(name: "Dana", phone: "+1 555 0100", email: "dana@example.com"), in: &config)
        _ = VoicePeople.save(PersonDraft(name: "Sam", email: "sam@example.com"), in: &config)
        settings.voiceLaunchJSON = config.encoded()
        for scheme in [ColorScheme.dark, .light] {
            let look = scheme == .dark ? "dark" : "light"
            try await render(VoiceLaunchView(), size: CGSize(width: 820, height: 1000), name: "voice-launch-\(look)", scheme: scheme)
            try await render(VoiceLaunchView(openCard: "whatsapp"), size: CGSize(width: 820, height: 1000), name: "voice-launch-open-\(look)", scheme: scheme)
        }
        try await render(VoiceLaunchView(tab: .people), size: CGSize(width: 820, height: 600), name: "voice-launch-people", scheme: .light)
        settings.voiceLaunchJSON = VoiceLaunchConfig.empty.encoded()
        try await render(VoiceLaunchView(), size: CGSize(width: 820, height: 1100), name: "voice-launch-empty", scheme: .light)
    }

    func testRenderStartupOverview() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let vm = DictatorViewModel.shared
        let previous = vm.setupSnapshot
        defer { if let previous { vm.showSetupSnapshot(previous) } }
        var picture = snapshot(localId: vm.localEdgeId, miniOnline: true)
        picture.machines[0].startup = .init(login: .disabled, showWindow: false)
        picture.machines[2].startup = .init(login: .needsApproval, showWindow: true)
        picture.machines[3].online = false
        picture.machines[3].startup = .init(login: .enabled, showWindow: false)
        vm.showSetupSnapshot(picture)
        try await render(GeneralSettingsPage(), size: CGSize(width: 820, height: 1050), name: "startup-general")
        try await render(YourMacsSettingsPage(), size: CGSize(width: 1100, height: 1450), name: "startup-setup")
    }

    private final class PreviewAdapter: WorkspaceLaunchAdapter {
        let granted: Bool
        init(granted: Bool) { self.granted = granted }
        var isAccessibilityGranted: Bool { granted }
        func requestPermission() {}
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) throws -> WorkspaceSnapshot {
            let window = WorkspaceRect(x: 100, y: 100, width: 600, height: 400)
            return WorkspaceSnapshot(
                displays: [WorkspaceDisplay(id: "a", name: "Built-in Retina Display", visibleFrame: WorkspaceRect(x: 0, y: 25, width: 1512, height: 957), isMain: true),
                           WorkspaceDisplay(id: "b", name: "LG UltraFine", visibleFrame: WorkspaceRect(x: 1512, y: -300, width: 2560, height: 1415))],
                windows: [WorkspaceWindow(id: "1", bundleID: "com.apple.Safari", appName: "Safari", frame: window),
                          WorkspaceWindow(id: "2", bundleID: "com.apple.mail", appName: "Mail", frame: window)])
        }
        func moveWindow(id: String, to frame: WorkspaceRect) throws {}
        func hideApp(bundleID: String) throws -> Bool { false }
        func unhideApp(bundleID: String) throws {}
        func retainWindows(ids: Set<String>) {}
    }

    private final class SnapshotFleet: WorkspaceFleet {
        var otherMacNames: [String] { ["MacBook Pro"] }
        func rememberEverywhere() async throws -> (layouts: [String: WorkspaceSavedLayout], unanswered: [String], busy: [String]) { ([:], [], []) }
        func runElsewhere(routineID: String, undo: Bool, operationID: String?) async throws -> [WorkspaceRunReport] { [] }
    }

    private func sampleLayouts() -> [String: WorkspaceSavedLayout] {
        let studio = WorkspaceDisplay(id: "s", name: "Studio Display", visibleFrame: WorkspaceRect(x: 0, y: 25, width: 2560, height: 1415), isMain: true)
        let mini = WorkspaceSavedLayout(macName: "Mac mini", capturedAt: Date(timeIntervalSinceReferenceDate: 781_000_000), screens: [studio], windows: [
            WorkspaceSavedWindow(bundleID: "com.apple.Terminal", appName: "Terminal", screenID: "s", place: WorkspaceRect(x: 0, y: 0, width: 0.4, height: 1)),
            WorkspaceSavedWindow(bundleID: "com.apple.Safari", appName: "Safari", screenID: "s", place: WorkspaceRect(x: 0.4, y: 0, width: 0.6, height: 0.6)),
            WorkspaceSavedWindow(bundleID: "com.apple.Notes", appName: "Notes", screenID: "s", place: WorkspaceRect(x: 0.4, y: 0.6, width: 0.6, height: 0.4)),
        ])
        let laptop = WorkspaceDisplay(id: "b", name: "Built-in Retina Display", visibleFrame: WorkspaceRect(x: 0, y: 25, width: 1512, height: 957), isMain: true, isBuiltIn: true)
        let lg = WorkspaceDisplay(id: "l", name: "LG UltraFine", visibleFrame: WorkspaceRect(x: 1512, y: -300, width: 2560, height: 1415))
        let book = WorkspaceSavedLayout(macName: "MacBook Pro", capturedAt: Date(timeIntervalSinceReferenceDate: 781_000_000), screens: [laptop, lg], windows: [
            WorkspaceSavedWindow(bundleID: "com.apple.mail", appName: "Mail", screenID: "b", place: WorkspaceRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)),
            WorkspaceSavedWindow(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", screenID: "l", place: WorkspaceRect(x: 0, y: 0, width: 0.5, height: 1)),
            WorkspaceSavedWindow(bundleID: "com.apple.Safari", appName: "Safari", screenID: "l", place: WorkspaceRect(x: 0.5, y: 0, width: 0.5, height: 1)),
        ])
        return [WorkspaceMacIdentity.current: mini, "book": book]
    }

    func testRenderWorkspaceLaunch() async throws {
        guard directory != nil else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let size = CGSize(width: 1000, height: 1100)

        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded())
        let fresh = WorkspaceLaunchController(adapter: PreviewAdapter(granted: false), settings: settings, macID: { "snap" })
        fresh.refreshPermission()
        try await render(WorkspaceLaunchView(controller: fresh, settings: settings), size: size, name: "w1-workspace-empty")

        var desk = WorkspaceStarter.sideBySide.routine()
        desk.name = "Writing desk"
        desk.actions[0].bundleIDs = ["com.apple.Safari", "com.apple.mail"]
        desk.actions[0].display = .right
        desk.hotkey = WorkspaceHotkey(keyCode: 18, modifiers: WorkspaceHotkey.control | WorkspaceHotkey.option)
        var tidy = WorkspaceStarter.hideIdle.routine()
        tidy.actions[0].bundleIDs = ["com.apple.Music"]
        tidy.enabled = false
        settings.workspaceLaunchJSON = try XCTUnwrap(WorkspaceLaunchConfig(routines: [desk, tidy, WorkspaceStarter.centerWindow.routine()]).encoded())
        let ready = WorkspaceLaunchController(adapter: PreviewAdapter(granted: true), settings: settings, macID: { "snap" })
        ready.refreshPermission()
        ready.fleet = SnapshotFleet()
        ready.preview(routineID: desk.id)
        for _ in 0..<200 where ready.isBusy || ready.previewPicture == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        try await render(WorkspaceLaunchView(controller: ready, settings: settings), size: CGSize(width: 1000, height: 1500), name: "w2-workspace-preview")

        try await render(WorkspaceRoutineEditor(routine: WorkspaceStarter.sideBySide.routine(), isNew: true) { _ in true },
                         size: CGSize(width: 640, height: 720), name: "w3-editor-starter")
        try await render(WorkspaceRoutineEditor(routine: desk, isNew: false) { _ in true }, size: CGSize(width: 640, height: 720), name: "w4-editor-filled")
        try await render(WorkspaceRoutineEditor(routine: WorkspaceRoutine(name: "", actions: []), isNew: true, controller: ready) { _ in true },
                         size: CGSize(width: 640, height: 720), name: "w5-editor-scratch")
        try await render(WorkspaceRoutineEditor(routine: .remembering(sampleLayouts(), existing: []), isNew: true, controller: ready) { _ in true },
                         size: CGSize(width: 640, height: 820), name: "w6-editor-remembered")
    }
}
