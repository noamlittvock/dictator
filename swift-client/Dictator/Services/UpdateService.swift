import Foundation
import Observation
import Sparkle

/// Sparkle owns this Mac's update preference; it never enters the settings mirror.
@MainActor
protocol UpdateDriver: AnyObject {
    var automaticallyChecksForUpdates: Bool { get set }
    var canCheckForUpdates: Bool { get }
    func start() throws
    func checkForUpdates()
}

@MainActor
@Observable
final class UpdateService {
    static let shared: UpdateService = {
        // Views can be constructed by hosted tests even though app startup is skipped.
        let testing = NSClassFromString("XCTestCase") != nil ||
            ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        return UpdateService(publicKey: testing ? nil : Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)
    }()

    private let updater: (any UpdateDriver)?
    let isActive: Bool
    var automaticallyChecksForUpdates: Bool {
        didSet { updater?.automaticallyChecksForUpdates = automaticallyChecksForUpdates }
    }

    init(publicKey: String?, makeUpdater: @MainActor () -> any UpdateDriver = { SparkleUpdateDriver() }) {
        let key = publicKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Also fail closed if an unexpanded build setting reaches a bundle.
        guard !key.isEmpty, !key.contains("$(") else {
            updater = nil
            isActive = false
            automaticallyChecksForUpdates = false
            return
        }
        let driver = makeUpdater()
        do {
            try driver.start()
            updater = driver
            isActive = true
            automaticallyChecksForUpdates = driver.automaticallyChecksForUpdates
        } catch {
            updater = nil
            isActive = false
            automaticallyChecksForUpdates = false
            NSLog("[Updates] Couldn’t start update checks: %@", error.localizedDescription)
        }
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates else { return }
        updater.checkForUpdates()
    }
}

@MainActor
private final class SparkleUpdateDriver: UpdateDriver {
    private let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }
    var canCheckForUpdates: Bool { controller.updater.canCheckForUpdates }

    func start() throws {
        controller.updater.sendsSystemProfile = false
        try controller.updater.start()
    }

    func checkForUpdates() { controller.checkForUpdates(nil) }
}
