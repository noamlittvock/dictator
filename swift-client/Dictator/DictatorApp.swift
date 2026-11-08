import AppKit
import Darwin
import SwiftData
import SwiftUI

@main
struct DictatorApp: App {
    // `.shared` so `ConnectionDetailsView` (constructed independently by
    // `SettingsView`, with no other route back to the running app) reads
    // and drives this same instance's `EdgeRuntime`/`CoreHost`.
    @State private var viewModel = DictatorViewModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    let sharedModelContainer: ModelContainer?

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
        } label: {
            menuBarIcon
                .modifier(DebugMainWindowOpener())
                .modifier(MainWindowRequestOpener())
                .modifier(FirstLaunchWindowOpener())
        }
        .menuBarExtraStyle(.menu)

        Window("Dictator", id: "main") {
            if let sharedModelContainer {
                MainWindowView()
                    .modelContainer(sharedModelContainer)
                    // One hub for the app's lifetime; the coordinator swaps
                    // its `current` between this Mac's store and the Core's.
                    .environment(\.repositoryHub, viewModel.repositoryHub)
            } else {
                PersistenceUnavailableSettingsView(message: viewModel.persistenceWarning)
            }
        }
        // Not smaller than `MainWindowView`'s minimum (820 × 560), so the
        // window doesn't open at one size and jump to another.
        .defaultSize(width: 960, height: 640)
        .commands {
            // Settings is a page of the main window, so ⌘, goes there.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { AppNavigation.shared.openSettings(.general) }
                    .keyboardShortcut(",", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Dictator Help") { AppNavigation.shared.openHelp() }
                    .keyboardShortcut("?", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var menuBarIcon: some View {
        switch viewModel.state {
        case .idle:
            if viewModel.micWarning != nil {
                // This Mac can't record right now (other Macs still can).
                Image(systemName: "mic.slash")
            } else {
                Image("MenuBarIcon")          // Dictator glyph (template, no text)
            }
        case .needsPermission(let message):
            if message.localizedCaseInsensitiveContains("microphone") {
                Image(systemName: "mic.badge.xmark")
            } else {
                Image(systemName: "lock.fill")
            }
        case .recording:
            Image("MenuBarIcon")
                .foregroundStyle(Color.dsPosterRed)
        case .processing:
            Image(systemName: "ellipsis.circle")
        case .error:
            Image(systemName: "exclamationmark.triangle")
        }
    }

    init() {
        // Hosted unit tests must not open personal history, register hotkeys,
        // or initialize the microphone.
        if NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            sharedModelContainer = nil
            return
        }
        if DevelopmentRuntimePolicy.blocksLiveRuntime(bundleID: Bundle.main.bundleIdentifier, arguments: CommandLine.arguments) {
            NSLog("[Startup] Development app runtime disabled. Open /Applications/Dictator.app, or explicitly pass --allow-development-runtime for development.")
            Darwin.exit(EXIT_SUCCESS)
        }
        let startup = StartupController.shared
        _ = UpdateService.shared
        // Explicit setup/administration request, never an implicit migration.
        if CommandLine.arguments.contains("--enable-login") { startup.setLogin(true) }
        NSLog("[Startup] login=%@ window=%@", startup.login.rawValue, startup.showWindow ? "shown" : "menu bar")
        HotkeyService.recordDiagnostics("startup login=\(startup.login.rawValue) window=\(startup.showWindow ? "shown" : "menu bar")")
        let persistence = PersistenceLoader.load()
        sharedModelContainer = persistence.container
        viewModel.modelContainer = persistence.container
        viewModel.setup()
        WorkspaceLaunchController.shared.start()
        if let warning = persistence.warning {
            viewModel.reportPersistenceIssue(warning)
        }
    }
}

struct PersistenceLoadResult {
    let container: ModelContainer?
    let warning: String?
}

enum PersistenceLoader {
    private static let storeFileName = "Dictator.store"
    private static let storeSuffixes = ["", "-shm", "-wal"]

    static func load() -> PersistenceLoadResult {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return load(applicationSupport: applicationSupport)
    }

    static func load(applicationSupport: URL) -> PersistenceLoadResult {
        let schema = Repositories.schema
        let fileManager = FileManager.default
        let dictatorDirectory = applicationSupport.appendingPathComponent(
            "Dictator", isDirectory: true
        )
        let storeURL = dictatorDirectory.appendingPathComponent(storeFileName)

        do {
            try fileManager.createDirectory(
                at: dictatorDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            // `attributes` only apply when this call makes the folder, and
            // other code can get there first.
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dictatorDirectory.path)
            return PersistenceLoadResult(
                container: try diskContainer(schema: schema, storeURL: storeURL),
                warning: nil
            )
        } catch {
            let originalError = error
            let recoveryDirectory = archiveStoreFiles(at: storeURL)
            do {
                let container = try diskContainer(schema: schema, storeURL: storeURL)
                let location = recoveryDirectory?.path ?? "the Dictator recovery folder"
                return PersistenceLoadResult(
                    container: container,
                    warning: "Dictator couldn’t open your history, so it started a new one. The old files are kept at \(location). Details: \(originalError.localizedDescription)"
                )
            } catch {
                do {
                    let memoryConfig = ModelConfiguration(
                        schema: schema, isStoredInMemoryOnly: true
                    )
                    let container = try ModelContainer(
                        for: schema, configurations: [memoryConfig]
                    )
                    return PersistenceLoadResult(
                        container: container,
                        warning: "Dictator can’t save history right now, so nothing from this session is kept after you quit. Details: \(error.localizedDescription)"
                    )
                } catch {
                    return PersistenceLoadResult(
                        container: nil,
                        warning: "Dictator couldn’t open or create your history. You can still dictate, but History and Dictionary are off. Quit and reopen Dictator to try again. Details: \(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private static func diskContainer(
        schema: Schema, storeURL: URL
    ) throws -> ModelContainer {
        let config = ModelConfiguration(schema: schema, url: storeURL)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @discardableResult
    private static func archiveStoreFiles(at storeURL: URL) -> URL? {
        let fileManager = FileManager.default
        let existing = storeSuffixes.compactMap { suffix -> URL? in
            let url = URL(fileURLWithPath: storeURL.path + suffix)
            return fileManager.fileExists(atPath: url.path) ? url : nil
        }
        guard !existing.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let recoveryDirectory = storeURL.deletingLastPathComponent()
            .appendingPathComponent("StoreRecovery", isDirectory: true)
            .appendingPathComponent(
                "\(formatter.string(from: Date()))-\(UUID().uuidString)",
                isDirectory: true
            )
        do {
            try fileManager.createDirectory(
                at: recoveryDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            for source in existing {
                try fileManager.moveItem(
                    at: source,
                    to: recoveryDirectory.appendingPathComponent(source.lastPathComponent)
                )
            }
            return recoveryDirectory
        } catch {
            NSLog("[Persistence] failed to preserve unreadable store: %@", error.localizedDescription)
            return nil
        }
    }
}

private struct PersistenceUnavailableSettingsView: View {
    let message: String?

    var body: some View {
        VStack(spacing: 0) {
            Label(
                message ?? "History isn’t being saved right now.",
                systemImage: "externaldrive.badge.exclamationmark"
            )
            .font(.dsSecondary)
            .foregroundStyle(Color.dsWarning)
            .padding(DSSpace.s)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            GeneralSettingsPage()
        }
        .tint(Color.dsAccent)
        .font(.dsBody)
        .buttonStyle(.dsSecondary)
        .background(Color.dsBgContent)
    }
}

/// Opens the main window when something outside a window asks for it
/// (`AppNavigation.openSettings`, e.g. clicking a dictation alert).
private struct MainWindowRequestOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow
    @State private var navigation = AppNavigation.shared

    func body(content: Content) -> some View {
        content.onChange(of: navigation.mainWindowRequests) { _, _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Dictator lives in the menu bar, whose icon can be hidden behind a busy
/// app's menus on a narrow screen. Opening Dictator again (Finder,
/// Spotlight, the Dock) brings its main window forward instead of doing
/// nothing.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let quitGuard = QuitGuard()

    /// `dictator://` links. The delegate receives them even when no window or
    /// menu is open, which SwiftUI's menu bar content can't promise.
    @MainActor func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            Task { @MainActor in await VoiceCommandTriggerController.shared.handleURL(url) }
        }
    }

    @MainActor func applicationDidFinishLaunching(_ notification: Notification) {
        quitGuard.start()
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        VoiceCommandTriggerController.shared.finishStarting()
    }

    /// Asked for every quit: the menu, an installer, or anything else.
    @MainActor func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitGuard.shouldTerminate(isBusy: { DictatorViewModel.shared.dictationInProgress },
            hasParkedWindows: { WorkspaceLaunchController.shared.hasParkedWindows },
            returnParkedWindows: { await WorkspaceLaunchController.shared.returnParkedWindowsBeforeQuit() }) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    @MainActor func applicationWillTerminate(_ notification: Notification) {
        DictatorViewModel.shared.flushDictionaryUsageOnQuit()
        DictatorViewModel.shared.cancelCLIOnQuit()
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppNavigation.shared.mainWindowRequests += 1 }
        return true
    }
}

/// The very first launch opens the main window (and its welcome) instead
/// of relying on the person finding the menu-bar icon.
private struct FirstLaunchWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            guard NSClassFromString("XCTestCase") == nil,
                  StartupController.shared.claimLaunchWindow(hasCompletedWelcome: AppSettings.shared.didCompleteWelcome) else { return }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Developer-only launch hook used by UI regression checks for this
/// menu-bar app. Normal launches are unchanged.
private struct DebugMainWindowOpener: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            #if DEBUG
            guard CommandLine.arguments.contains("--show-main-window") else { return }
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
            #endif
        }
    }
}
