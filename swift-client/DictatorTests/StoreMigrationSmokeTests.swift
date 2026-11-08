import SwiftData
import XCTest
@testable import Dictator

/// Opens a copy of a real `Dictator.store` (pointed at by
/// `DICTATOR_MIGRATION_STORE_DIR`, a directory that contains a `Dictator/`
/// folder with the store files) through `PersistenceLoader` and checks the
/// lightweight migration to the current schema leaves every row readable.
/// Skipped unless the variable is set — a deployment preflight, not a
/// unit test.
final class StoreMigrationSmokeTests: XCTestCase {
    @MainActor
    func testRealStoreOpensWithoutRecovery() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DICTATOR_MIGRATION_STORE_DIR"], !dir.isEmpty else {
            throw XCTSkip("DICTATOR_MIGRATION_STORE_DIR not set")
        }
        let expectedCount = Int(ProcessInfo.processInfo.environment["DICTATOR_MIGRATION_EXPECTED_ROWS"] ?? "")
        let result = PersistenceLoader.load(applicationSupport: URL(fileURLWithPath: dir))
        XCTAssertNil(result.warning, "migration must not fall back to recovery: \(result.warning ?? "")")
        let container = try XCTUnwrap(result.container)
        let repositories = Repositories.make(container: container)

        let manifest = try await repositories.historySync.localManifest()
        if let expectedCount {
            XCTAssertEqual(manifest.count, expectedCount)
        }
        XCTAssertTrue(manifest.allSatisfy(\.pending), "pre-migration rows must read as pending (syncedAt nil)")
        let page = try await repositories.history.page(limit: 5, before: nil)
        XCTAssertFalse(page.isEmpty)
        XCTAssertNil(page.first?.originEdgeId)
        XCTAssertEqual(try repositories.outbox.count(), 0)
        let stats = try await repositories.history.stats()
        XCTAssertNotNil(stats)
        print("MIGRATION-SMOKE rows=\(manifest.count) newest=\(page.first?.timestamp.description ?? "-") stats=\(String(describing: stats))")
    }
}
