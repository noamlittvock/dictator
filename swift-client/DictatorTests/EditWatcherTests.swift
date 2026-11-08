import XCTest
@testable import Dictator

@MainActor final class EditWatcherTests: XCTestCase {
    private final class Reader: EditAccessibilityReader {
        var onMoveOn: (() -> Void)?
        var starts = 0, reads = 0, stops = 0
        var snapshot: EditSpanSnapshot? = .match(value: "before Zandor after", caret: 13, inserted: "Zandor")
        var after: String? = "Xandor"
        func begin(inserted: String, expectedBundleID: String?) -> EditSpanSnapshot? { starts += 1; return snapshot }
        func editedSpan(_ snapshot: EditSpanSnapshot) -> String? { reads += 1; return after }
        func stop() { stops += 1 }
    }

    func testOneReadAfterInsertionOneOnFocusLeaveAndNothingBetween() {
        let reader = Reader(); var reports: [CorrectionReport] = []
        let watcher = EditWatcher(reader: reader, allowed: { _ in true }, deliver: { reports.append($0) })
        let id = UUID()
        watcher.inserted("Zandor", entryID: id, context: CaptureContext())
        XCTAssertEqual(reader.starts, 1); XCTAssertEqual(reader.reads, 0); XCTAssertTrue(reports.isEmpty)
        reader.onMoveOn?()
        XCTAssertEqual(reader.reads, 1); XCTAssertEqual(reports.first?.entryID, id)
        XCTAssertEqual(reports.first?.corrected, "Xandor")
        reader.onMoveOn?(); watcher.finish()
        XCTAssertEqual(reader.reads, 1)
    }

    func testDisallowedObservationNeverReads() {
        let reader = Reader()
        let watcher = EditWatcher(reader: reader, allowed: { _ in false }, deliver: { _ in XCTFail() })
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext()); watcher.finish()
        XCTAssertEqual(reader.starts, 0); XCTAssertEqual(reader.reads, 0)
    }

    func testRevocationCancelsFinalRead() {
        let reader = Reader(); var allowed = true
        let watcher = EditWatcher(reader: reader, allowed: { _ in allowed }, deliver: { _ in XCTFail() })
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext())
        allowed = false; watcher.finish()
        XCTAssertEqual(reader.reads, 0)
    }

    func testUnavailableAndSecureReadersAreQuiet() {
        let reader = Reader(); reader.snapshot = nil
        let watcher = EditWatcher(reader: reader, allowed: { _ in true }, deliver: { _ in XCTFail() })
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext()); watcher.finish()
        XCTAssertEqual(reader.reads, 0)
    }

    func testNextInsertionFinishesPreviousAndCancelDoesNotRead() {
        let reader = Reader(); var reports = 0
        let watcher = EditWatcher(reader: reader, allowed: { _ in true }, deliver: { _ in reports += 1 })
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext())
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext())
        XCTAssertEqual(reports, 1); watcher.cancel()
        XCTAssertEqual(reader.reads, 1)
    }

    func testUnchangedOrUnreadableFinalSpanDoesNotReport() {
        for after: String? in [nil, "Zandor", "Zandor this is unrelated typing", "Xandor this is unrelated typing"] {
            let reader = Reader(); reader.after = after
            let watcher = EditWatcher(reader: reader, allowed: { _ in true }, deliver: { _ in XCTFail() })
            watcher.inserted("Zandor", entryID: nil, context: CaptureContext()); watcher.finish()
        }
    }

    func testCapFinishesOnce() async throws {
        let reader = Reader(); var reports = 0
        let watcher = EditWatcher(reader: reader, timeCap: 0.01, allowed: { _ in true }, deliver: { _ in reports += 1 })
        watcher.inserted("Zandor", entryID: nil, context: CaptureContext())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(reports, 1); XCTAssertEqual(reader.reads, 1)
    }

    func testNeighboursLocateOnlyInsertedSpanAndRejectDrift() throws {
        let snapshot = try XCTUnwrap(EditSpanSnapshot.match(value: "prefix Zandor suffix", caret: 13, inserted: "Zandor"))
        XCTAssertEqual(snapshot.locate(in: "prefix Xandor suffix"), "Xandor")
        XCTAssertNil(snapshot.locate(in: "prefix Xandor unrelated"))
        XCTAssertNil(snapshot.locate(in: "other Xandor suffix"))
        XCTAssertNil(EditSpanSnapshot.match(value: "prefix Zandor suffix", caret: 2, inserted: "Zandor"))
    }

    func testBoundaryTypingAndAmbiguousAnchorsCannotLeaveWatcher() throws {
        for after in ["SuperCompany hunter", "hunter SuperCompany", "SuperCompanyhunter", "hunterSuperCompany", "SuperCompanyberry", "SuperCompany hunter after", "Super Company"] {
            let reader = Reader()
            reader.snapshot = .match(value: "SuperCompony", caret: 12, inserted: "SuperCompony")
            reader.after = after
            let watcher = EditWatcher(reader: reader, allowed: { _ in true }, deliver: { _ in XCTFail("Unowned typing was sent: \(after)") })
            watcher.inserted("SuperCompony", entryID: UUID(), context: CaptureContext())
            watcher.finish()
        }
        let end = try XCTUnwrap(EditSpanSnapshot.match(value: "Ask SuperCompony", caret: 16, inserted: "SuperCompony"))
        XCTAssertNil(end.locate(in: "Ask SuperCompany hunter"))
        XCTAssertEqual(end.locate(in: "Ask SuperCompany"), "SuperCompany")
        let start = try XCTUnwrap(EditSpanSnapshot.match(value: "SuperCompony after", caret: 12, inserted: "SuperCompony"))
        XCTAssertNil(start.locate(in: "hunter SuperCompany after"))
        let anchored = try XCTUnwrap(EditSpanSnapshot.match(value: "prefix Zandor suffix", caret: 13, inserted: "Zandor"))
        XCTAssertNil(anchored.locate(in: "prefix Xandor suffix suffix"))
        XCTAssertNil(EditSpanSnapshot.match(value: String(repeating: "prefix Zandor suffix ", count: 6), caret: 13, inserted: "Zandor"))
        XCTAssertNil(EditSpanSnapshot.match(value: "otherZandor", caret: 11, inserted: "Zandor"))
    }

    func testConsentGateBlocksReadsForPauseAndEitherExclusionButNotHistoryOff() {
        let settings = AppSettings.shared
        let old = (settings.persistHistory, settings.learnFromCorrections, settings.cachedSurfacePolicyJSON, settings.promptCapturePausedUntil)
        defer {
            settings.persistHistory = old.0; settings.learnFromCorrections = old.1
            settings.cachedSurfacePolicyJSON = old.2; settings.promptCapturePausedUntil = old.3
        }
        settings.persistHistory = false; settings.learnFromCorrections = true
        settings.promptCapturePausedUntil = nil
        settings.updateCachedSurfacePolicy(SurfacePolicy(defaultTyped: "ignore", defaultVoice: "save"))
        let context = CaptureContext(appBundleID: "test.synthetic")
        XCTAssertTrue(settings.correctionObservationAllowed(for: context), "Learning is independent of history")
        for modality in ["typed", "voice"] {
            settings.updateCachedSurfacePolicy(SurfacePolicy(rules: [.init(kind: "app", pattern: "test.synthetic", action: "ignore", modality: modality)]))
            let reader = Reader()
            let watcher = EditWatcher(reader: reader, allowed: { settings.correctionObservationAllowed(for: $0) }, deliver: { _ in XCTFail() })
            watcher.inserted("Zandor", entryID: nil, context: context); watcher.finish()
            XCTAssertEqual(reader.starts, 0); XCTAssertEqual(reader.reads, 0)
        }
        settings.updateCachedSurfacePolicy(SurfacePolicy())
        let reader = Reader()
        let watcher = EditWatcher(reader: reader, allowed: { settings.correctionObservationAllowed(for: $0) }, deliver: { _ in XCTFail() })
        watcher.inserted("Zandor", entryID: nil, context: context)
        settings.promptCapturePausedUntil = .distantFuture
        watcher.finish()
        XCTAssertEqual(reader.starts, 1); XCTAssertEqual(reader.reads, 0)
        watcher.inserted("Zandor", entryID: nil, context: context)
        XCTAssertEqual(reader.starts, 1)
    }

    func testTypedOffSendsOnlyFilteredPairsWithoutSentence() {
        let reader = Reader()
        reader.snapshot = .match(value: "Ask Zandor tomorrow", caret: 19, inserted: "Ask Zandor tomorrow")
        reader.after = "Ask Xandor tomorrow"
        var reports: [CorrectionReport] = []
        let watcher = EditWatcher(reader: reader, allowed: { _ in true }, prepare: { report, _ in
            CorrectionLearningService.reports(report, keepSentence: false, languages: [], isKnownWord: { _ in false })
        }, deliver: { reports.append($0) })
        watcher.inserted("Ask Zandor tomorrow", entryID: UUID(), context: CaptureContext())
        watcher.finish()
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports.first?.heard, "Zandor"); XCTAssertEqual(reports.first?.corrected, "Xandor")
        XCTAssertEqual(reports.first?.pairsOnly, true)
        XCTAssertTrue(CorrectionLearningService.reports(.init(heard: "from", corrected: "form"), keepSentence: false, languages: [], isKnownWord: { _ in true }).isEmpty)
    }

}
