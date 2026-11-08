import XCTest
@testable import Dictator

@MainActor
final class WorkspaceLaunchExecutorTests: XCTestCase {
    private final class FakeAdapter: WorkspaceLaunchAdapter {
        var isAccessibilityGranted = true
        var frontmostBundleID: String? = "other"
        var order: [WorkspaceStackWindow] = []
        var raised: [String] = []
        var focusReturns: [String] = []
        var refused = Set<String>()
        var silentRefusals = Set<String>()
        func liveWindowOrder(deadline: TimeInterval) async -> [WorkspaceStackWindow] { order }
        func makeAppFrontmost(bundleID: String, deadline: TimeInterval) async throws {
            focusReturns.append(bundleID)
            frontmostBundleID = bundleID
            order = order.filter { $0.bundleID == bundleID } + order.filter { $0.bundleID != bundleID }
        }
        func raiseWindow(id: String, deadline: TimeInterval) async throws {
            raised.append(id)
            if refused.contains(id) { throw WorkspaceLaunchError.unavailable("Synthetic refusal") }
            if silentRefusals.contains(id) { return }
            guard let window = order.first(where: { $0.id == id }) else { return }
            if frontmostBundleID != window.bundleID {
                // Synthetic app activation raises all of its windows.
                order = order.filter { $0.bundleID == window.bundleID } + order.filter { $0.bundleID != window.bundleID }
                frontmostBundleID = window.bundleID
            }
            order.removeAll { $0.id == id }; order.insert(window, at: 0)
        }
        var moves: [(String, WorkspaceRect)] = []
        var hides: [String] = []
        var unhides: [String] = []
        var failingWindow: String?
        var permanentlyMissing = false
        var alreadyHiddenAtExecution = false
        func requestPermission() { XCTFail("Tests must never request machine permission") }
        func capture(lastActivatedAt: [String: Date], excluding: Set<String>, preferredFrontmostBundleID: String?, windowBundleIDs: Set<String>, applicationBundleIDs: Set<String>) throws -> WorkspaceSnapshot {
            XCTFail("Executor must use its injected snapshot")
            return WorkspaceSnapshot()
        }
        func moveWindow(id: String, to frame: WorkspaceRect) throws {
            moves.append((id, frame))
            if id == failingWindow {
                if permanentlyMissing { throw NativeResetError.windowNotFound(id) }
                throw WorkspaceLaunchError.unavailable("Synthetic failure")
            }
        }
        func hideApp(bundleID: String) throws -> Bool { if alreadyHiddenAtExecution { return false }; hides.append(bundleID); return true }
        func unhideApp(bundleID: String) throws { unhides.append(bundleID) }
        func retainWindows(ids: Set<String>) {}
    }
    private let original = WorkspaceRect(x: -500, y: 40, width: 400, height: 300)

    private func stackWindow(_ id: String, app: String? = nil, x: Double = 0) -> WorkspaceStackWindow {
        .init(id: id, bundleID: app ?? id, frame: .init(x: x, width: 500, height: 500))
    }

    func testStackAlreadyRightAndOffDesktopDoNothingIncludingFocus() async {
        let adapter = FakeAdapter()
        adapter.order = [stackWindow("front"), stackWindow("back")]
        var plan = WorkspacePlan()
        plan.windowStack = ["absent", "back", "front"]
        let result = await WorkspaceLaunchExecutor.applyCooperatively(plan, snapshot: .init(), adapter: adapter)
        XCTAssertTrue(adapter.raised.isEmpty)
        XCTAssertTrue(adapter.focusReturns.isEmpty)
        XCTAssertEqual(result.stack?.passes, 0)
        XCTAssertEqual(result.stack?.finalBundleOrder, ["front", "back"])
        XCTAssertEqual(result.stack?.diagnostic, "workspace: stack passes=0 lifted=0 order=front,back focusBack=0")
    }

    func testStackCorrectsAppActivationOvershootOnNextPass() async {
        let adapter = FakeAdapter()
        adapter.frontmostBundleID = "b"
        adapter.order = [stackWindow("b"), stackWindow("sibling", app: "a"), stackWindow("a")]
        let result = await adapter.applyWindowStack(["a", "b"], snapshot: .init(), deadline: adapter.monotonicTime + 5)
        XCTAssertEqual(adapter.raised, ["a", "b"])
        XCTAssertEqual(result.passes, 2)
        XCTAssertEqual(result.finalBundleOrder, ["b", "a"])
        XCTAssertTrue(result.notes.isEmpty)
        XCTAssertTrue(adapter.focusReturns.isEmpty, "Returning the overlapping previous app is unnecessary")
    }

    func testFailedStackWindowsProduceOneAppNoteAndOthersContinue() async {
        let adapter = FakeAdapter()
        adapter.order = [stackWindow("cover"), stackWindow("bad1", app: "code"), stackWindow("bad2", app: "code"), stackWindow("ok")]
        adapter.refused = ["bad1", "bad2"]
        let snapshot = WorkspaceSnapshot(windows: [
            .init(id: "bad1", bundleID: "code", appName: "VS Code"),
            .init(id: "bad2", bundleID: "code", appName: "VS Code"), .init(id: "ok", bundleID: "ok")
        ])
        var plan = WorkspacePlan(); plan.windowStack = ["bad1", "bad2", "ok"]
        let result = await WorkspaceLaunchExecutor.applyCooperatively(plan, snapshot: snapshot, adapter: adapter)
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertTrue(adapter.raised.contains("ok"))
        XCTAssertEqual(result.stack?.notes, ["VS Code wouldn't come to the front."])
        XCTAssertEqual(result.stack?.passes, 3)
    }

    func testStackAcknowledgementWithoutEffectIsReportedAfterThreePasses() async {
        let adapter = FakeAdapter()
        adapter.order = [stackWindow("cover"), stackWindow("code")]
        adapter.silentRefusals = ["code"]
        let result = await adapter.applyWindowStack(["code"], snapshot: .init(windows: [.init(id: "code", bundleID: "code", appName: "VS Code")]), deadline: adapter.monotonicTime + 5)
        XCTAssertEqual(adapter.raised, ["code", "code", "code"])
        XCTAssertEqual(result.notes, ["VS Code wouldn't come to the front."])
    }

    func testFocusReturnsWhenSeparateAndAlwaysForDictator() async {
        for dictator in [false, true] {
            let adapter = FakeAdapter()
            adapter.frontmostBundleID = dictator ? adapter.dictatorBundleID : "separate"
            adapter.order = [stackWindow("old", app: adapter.frontmostBundleID, x: dictator ? 0 : 700), stackWindow("cover"), stackWindow("a")]
            let result = await adapter.applyWindowStack(["a"], snapshot: .init(), deadline: adapter.monotonicTime + 5)
            XCTAssertEqual(adapter.raised, ["a"])
            XCTAssertEqual(adapter.focusReturns, [dictator ? adapter.dictatorBundleID : "separate"])
            XCTAssertTrue(result.focusRestored)
        }
    }

    func testEnhancedUIReadbackWinsWhenDisableAndRestoreReturnErrorsAfterChangingState() throws {
        var enabled = true
        var writes: [Bool] = []
        var adjusted = false
        try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { enabled }, write: {
                enabled = $0; writes.append($0)
                throw NativeResetError.moveFailed("synthetic ACK=-25208 after applied state")
            }, pause: { _ in }, diagnostic: { _ in }, restorationPending: { XCTFail("restored state is observed") },
            adjustment: { XCTAssertFalse(enabled); adjusted = true })
        XCTAssertTrue(adjusted)
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [false, true])
    }

    func testEnhancedUIFirstTrueReadAfterRejectedDisableStillRequiresRestoration() throws {
        var writes: [Bool] = []
        var adjusted = false
        try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { true }, write: { writes.append($0); throw NativeResetError.moveFailed("synthetic ACK=-25208, unchanged") },
            pause: { _ in }, diagnostic: { _ in }, restorationPending: { XCTFail("nothing changed") },
            adjustment: { adjusted = true })
        XCTAssertTrue(adjusted)
        XCTAssertEqual(writes, [false, true])
    }

    func testEnhancedUIDelayedDisableAfterFirstTrueReadIsRestoredAfterAdjustment() throws {
        var enabled = true
        var disableQueued = false
        var writes: [Bool] = []
        var adjusted = false
        try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { enabled }, write: {
                writes.append($0)
                if !$0 { disableQueued = true }
                else { enabled = true; disableQueued = false }
            }, pause: { _ in }, diagnostic: { _ in }, restorationPending: { XCTFail("restore succeeds") },
            adjustment: {
                XCTAssertTrue(enabled, "first post-disable read was still true")
                XCTAssertTrue(disableQueued)
                enabled = false // The queued disable arrives during the adjustment.
                adjusted = true
            })
        XCTAssertTrue(adjusted)
        XCTAssertTrue(enabled)
        XCTAssertFalse(disableQueued)
        XCTAssertEqual(writes, [false, true])
    }

    func testEnhancedUIDelayedDisableWithFailedRestorationKeepsPendingIntent() {
        var enabled = true
        var pending = false
        var writes: [Bool] = []
        XCTAssertThrowsError(try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { enabled }, write: {
                writes.append($0)
                if $0 { throw NativeResetError.moveFailed("synthetic restore failure, state unchanged") }
            }, pause: { _ in }, diagnostic: { _ in }, restorationPending: { pending = true },
            adjustment: { enabled = false })) {
                guard case NativeResetError.accessibilityRestorePending = $0 else { return XCTFail("pending restoration must be explicit") }
            }
        XCTAssertFalse(enabled, "delayed disable arrived after the initial true read")
        XCTAssertTrue(pending)
        XCTAssertEqual(writes, [false, true, true, true])
    }

    func testEnhancedUIDelayedDisableAfterFirstRestoreReadTriggersAnotherRestoreWrite() throws {
        var enabled = true
        var delayedDisable = false
        var pauses = 0
        var writes: [Bool] = []
        try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { enabled }, write: {
                writes.append($0)
                if !$0 { delayedDisable = true } else { enabled = true }
            }, pause: { _ in
                pauses += 1
                if pauses == 2, delayedDisable { enabled = false; delayedDisable = false }
            }, diagnostic: { _ in }, restorationPending: { XCTFail("second restoration succeeds") }, adjustment: {})
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes, [false, true, true], "a first true restore read cannot end the obligation")
    }

    func testEnhancedUIEveryAttemptedDisableRestoresForAllPostReadAndAdjustmentOutcomes() throws {
        for postRead in [true as Bool?, false, nil] {
            for adjustmentThrows in [false, true] {
                var enabled = true
                var reads = 0
                var writes: [Bool] = []
                var pending = false
                var adjustments = 0
                let operation = {
                    try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
                        read: {
                            reads += 1
                            return reads == 2 ? postRead : enabled
                        }, write: { enabled = $0; writes.append($0) }, pause: { _ in }, diagnostic: { _ in },
                        restorationPending: { pending = true }, adjustment: {
                            adjustments += 1
                            if adjustmentThrows { throw NativeResetError.moveFailed("synthetic geometry failure") }
                        })
                }
                if postRead == nil || adjustmentThrows { XCTAssertThrowsError(try operation()) }
                else { try operation() }
                XCTAssertTrue(enabled)
                XCTAssertFalse(pending)
                XCTAssertEqual(adjustments, postRead == nil ? 0 : 1)
                XCTAssertEqual(writes, [false, true])
            }
        }
    }

    func testEnhancedUIOffUnknownUnsettableAndBuiltInAssistiveCasesAreNotChanged() throws {
        for (original, settable, assistive) in [(false as Bool?, true as Bool?, false), (nil, true, false), (true, false, false), (true, nil, false), (true, true, true)] {
            var adjusted = false
            try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: assistive, settable: settable,
                read: { original }, write: { _ in XCTFail("mode must not change") }, pause: { _ in },
                diagnostic: { _ in }, restorationPending: { XCTFail("nothing changed") }, adjustment: { adjusted = true })
            XCTAssertTrue(adjusted)
        }
    }

    func testEnhancedUIRestoresPriorStateWhenGeometryThrows() {
        var enabled = true
        XCTAssertThrowsError(try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: { enabled }, write: { enabled = $0 }, pause: { _ in }, diagnostic: { _ in },
            restorationPending: { XCTFail("restore succeeds") }, adjustment: { throw NativeResetError.moveFailed("geometry failed") }))
        XCTAssertTrue(enabled)
    }

    func testEnhancedUIFailedRestorationRetainsIntentAndLaterRetryRestoresActualState() {
        var enabled = true
        var restoreBlocked = true
        var pending = false
        var writes: [Bool] = []
        let read = { enabled }
        let write: (Bool) throws -> Void = { value in
            writes.append(value)
            if value && restoreBlocked { throw NativeResetError.moveFailed("synthetic temporary restore failure") }
            enabled = value
        }
        XCTAssertThrowsError(try WorkspaceFrameAccessibilityScope.perform(builtInAssistiveActive: false, settable: true,
            read: read, write: write, pause: { _ in }, diagnostic: { _ in }, restorationPending: { pending = true }, adjustment: {})) {
            guard case NativeResetError.accessibilityRestorePending = $0 else { return XCTFail("pending state must be explicit") }
        }
        XCTAssertTrue(pending)
        XCTAssertFalse(enabled)
        XCTAssertEqual(writes, [false, true, true, true], "restore attempts must be bounded")
        restoreBlocked = false
        if WorkspaceFrameAccessibilityScope.restore(read: read, write: write, pause: { _ in }, diagnostic: { _ in }) { pending = false }
        XCTAssertFalse(pending)
        XCTAssertTrue(enabled)
        XCTAssertEqual(writes.last, true)
    }

    func testNativeGeometryWaitsForStaleReadbackThenAcceptsTheSettledFrame() throws {
        let target = WorkspaceRect(x: 540, y: 25, width: 540, height: 1810)
        var reads = 0
        var writes: [String] = []
        var pauses = 0
        try WorkspaceFrameApplication.apply(original: original, target: target,
            setSize: { _ in writes.append("size") }, setPosition: { _ in writes.append("position") },
            readFrame: { reads += 1; return reads < 3 ? self.original : target },
            pause: { _ in pauses += 1 })
        XCTAssertGreaterThanOrEqual(reads, 3)
        XCTAssertGreaterThanOrEqual(pauses, 2)
        XCTAssertEqual(writes, ["position", "size", "position"], "stale reads must not trigger rollback")
    }

    func testNativeGeometryFinishesCrossDisplayMoveWhenOldSizeClampsInitialPosition() throws {
        let target = WorkspaceRect(x: 540, y: 25, width: 540, height: 1810)
        var actual = original
        actual.width = 900
        var writes: [String] = []
        try WorkspaceFrameApplication.apply(original: original, target: target,
            setSize: { actual.width = $0.width; actual.height = $0.height; writes.append("size") },
            setPosition: {
                actual.x = actual.width > $0.width ? $0.x - 100 : $0.x
                actual.y = $0.y
                writes.append("position")
            }, readFrame: { actual }, pause: { _ in })
        XCTAssertEqual(actual, target)
        XCTAssertEqual(writes, ["position", "size", "position"])
    }

    func testNativeGeometryMovesBeforeQueuedFullHeightResizeToAvoidOldOriginClamp() throws {
        let original = WorkspaceRect(x: 116, y: 166, width: 590, height: 490)
        let target = WorkspaceRect(x: 0, y: 30, width: 540, height: 1890)
        var actual = original
        var pending: [WorkspaceRect] = []
        var writes: [String] = []
        var pauseCount = 0
        var diagnostics: [String] = []
        // Successful AX setters enqueue complete frames based on the frame
        // at call time. A resize at y166 can be at most1754 tall on this
        //1920-point screen, and later overwrites an interleaved position.
        try WorkspaceFrameApplication.apply(original: original, target: target,
            setSize: {
                writes.append("size")
                pending.append(WorkspaceRect(x: actual.x, y: actual.y, width: $0.width,
                                             height: min($0.height, 1920 - actual.y)))
            }, setPosition: {
                writes.append("position")
                pending.append(WorkspaceRect(x: $0.x, y: $0.y, width: actual.width, height: actual.height))
            }, readFrame: { actual }, pause: { _ in
                pauseCount += 1
                guard pauseCount.isMultiple(of: 3) else { return }
                for frame in pending { actual = frame }
                pending.removeAll()
            }, diagnostic: { diagnostics.append($0) })
        XCTAssertEqual(actual, target)
        XCTAssertTrue(diagnostics.contains { $0.contains("stage=initial-size attempt=3") }, "size must be confirmed after asynchronous completion")
        XCTAssertFalse(diagnostics.contains { $0.contains("height: 1754.0") }, "do not introduce the known old-origin clamp")
        XCTAssertEqual(writes, ["position", "size", "position"])
    }

    func testNativeGeometryPersistentMismatchIsBoundedAndRestoresOriginal() {
        let target = WorkspaceRect(x: 540, y: 25, width: 540, height: 1810)
        var actual = original
        var reads = 0
        var diagnostics: [String] = []
        XCTAssertThrowsError(try WorkspaceFrameApplication.apply(original: original, target: target,
            setSize: { actual.width = $0.width; actual.height = $0.height },
            setPosition: { actual.x = $0.x; actual.y = $0.y },
            readFrame: { reads += 1; var mismatch = actual; mismatch.x += 100; return mismatch },
            pause: { _ in }, diagnostic: { diagnostics.append($0) }))
        XCTAssertLessThanOrEqual(reads, 24)
        XCTAssertGreaterThanOrEqual(reads, 6)
        XCTAssertEqual(actual, original)
        XCTAssertTrue(diagnostics.contains { $0.contains("desired=") && $0.contains("observed=") })
    }

    func testNativeGeometrySetterErrorRollsBackThePartiallyChangedFrame() {
        let target = WorkspaceRect(x: 540, y: 25, width: 540, height: 1810)
        var actual = original
        var reads = 0
        var diagnostics: [String] = []
        XCTAssertThrowsError(try WorkspaceFrameApplication.apply(original: original, target: target,
            setSize: { actual.width = $0.width; actual.height = $0.height },
            setPosition: {
                if $0 == target { actual.x = $0.x; throw NativeResetError.moveFailed("synthetic AX error=-25204") }
                actual.x = $0.x; actual.y = $0.y
            }, readFrame: { reads += 1; return actual }, pause: { _ in },
            diagnostic: { diagnostics.append($0) }))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(actual, original)
        XCTAssertTrue(diagnostics.contains { $0.contains("-25204") })
        XCTAssertFalse(NativeResetError.frameMismatch("synthetic").localizedDescription.contains("minimum size"))
    }

    func testReadableInvalidSaveKeepsTheOriginalDefinitionsAndShowsTheProblem() throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let original = try XCTUnwrap(WorkspaceLaunchConfig.empty.encoded())
        settings.workspaceLaunchJSON = original
        let controller = WorkspaceLaunchController(adapter: FakeAdapter(), settings: settings)
        let routine = WorkspaceRoutine(name: "Reserved", hotkey: WorkspaceHotkey(keyCode: 53, modifiers: WorkspaceHotkey.command | WorkspaceHotkey.option), actions: [WorkspaceAction(kind: .centerLastWindow)])
        XCTAssertFalse(controller.saveRoutine(routine))
        XCTAssertEqual(settings.workspaceLaunchJSON, original)
        XCTAssertEqual(controller.status, "Command-Option-Escape is reserved for Force Quit")
    }

    func testLegacyAndDuplicateShortcutsPreserveRawSettingsUntilTheUserSaves() throws {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        let key = WorkspaceHotkey(keyCode: 15, modifiers: 6400)
        let config = WorkspaceLaunchConfig(routines: [
            WorkspaceRoutine(name: "First", hotkey: key, actions: [WorkspaceAction(kind: .centerLastWindow)]),
            WorkspaceRoutine(name: "Second", hotkey: key, actions: [WorkspaceAction(kind: .centerLastWindow)])])
        let raw = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        settings.workspaceLaunchJSON = raw
        let controller = WorkspaceLaunchController(adapter: FakeAdapter(), settings: settings)
        XCTAssertEqual(settings.workspaceLaunchJSON, raw)
        XCTAssertEqual(settings.workspaceLaunch.routines.count, 2)
        XCTAssertTrue(settings.workspaceLaunch.routines[0].enabled)
        XCTAssertFalse(settings.workspaceLaunch.routines[1].enabled)
        XCTAssertNil(settings.workspaceLaunch.routines[1].hotkey)
        XCTAssertNotNil(controller.savedSettingsWarning)
        XCTAssertFalse(controller.canClearUnreadableSettings)
        XCTAssertTrue(controller.saveRoutine(settings.workspaceLaunch.routines[1]))
        XCTAssertNotEqual(settings.workspaceLaunchJSON, raw)
        XCTAssertNil(controller.savedSettingsWarning)
        XCTAssertEqual(settings.workspaceLaunch.routines.count, 2)
    }

    func testMalformedSettingsBlockControllerWritesUntilExplicitReset() {
        let settings = AppSettings.shared
        let saved = settings.workspaceLaunchJSON
        defer { settings.workspaceLaunchJSON = saved }
        settings.workspaceLaunchJSON = "malformed"
        let controller = WorkspaceLaunchController(adapter: FakeAdapter(), settings: settings)
        XCTAssertFalse(controller.saveRoutine(WorkspaceRoutine(name: "New", actions: [WorkspaceAction(kind: .centerLastWindow)])))
        controller.deleteRoutine(id: "missing")
        XCTAssertEqual(settings.workspaceLaunchJSON, "malformed")
        XCTAssertNotNil(controller.savedSettingsWarning)
        controller.resetSavedRoutines()
        XCTAssertEqual(settings.workspaceLaunch, .empty)
        XCTAssertNil(controller.savedSettingsWarning)
    }

    func testAppAlreadyHiddenAtExecutionIsNotAddedToRecovery() async {
        let adapter = FakeAdapter()
        adapter.alreadyHiddenAtExecution = true
        let result = await WorkspaceLaunchExecutor.apply(WorkspacePlan(operations: [.hideApp(bundleID: "app")]),
            snapshot: WorkspaceSnapshot(applications: [WorkspaceApplication(bundleID: "app")]), adapter: adapter)
        XCTAssertEqual(result.completed, 0)
        XCTAssertTrue(result.recovery.isEmpty)
    }

    func testAppUsedDuringExecutionIsNeverHidden() async {
        let adapter = FakeAdapter()
        let snapshot = WorkspaceSnapshot(applications: [WorkspaceApplication(bundleID: "used")])
        let result = await WorkspaceLaunchExecutor.applyCooperatively(WorkspacePlan(operations: [.hideApp(bundleID: "used")]),
            snapshot: snapshot, adapter: adapter, isAppStillIdle: { _ in false })
        XCTAssertTrue(adapter.hides.isEmpty)
        XCTAssertTrue(result.recovery.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testClosedWindowIsDroppedFromRecoveryInsteadOfRetryingForever() async {
        let adapter = FakeAdapter()
        adapter.failingWindow = "closed"
        adapter.permanentlyMissing = true
        let recovery = WorkspaceRecovery(windows: [WorkspaceWindow(id: "closed", bundleID: "app", frame: original)])
        let result = await WorkspaceLaunchExecutor.restoreCooperatively(recovery, adapter: adapter)
        XCTAssertTrue(result.recovery.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }

    func testCooperativeExecutionPreservesRecoveryAndStopsOnFailure() async {
        let adapter = FakeAdapter()
        adapter.failingWindow = "w2"
        let snapshot = WorkspaceSnapshot(windows: [WorkspaceWindow(id: "w1", bundleID: "app", frame: original),
            WorkspaceWindow(id: "w2", bundleID: "app", frame: original)])
        let plan = WorkspacePlan(operations: [.moveWindow(id: "w1", frame: original), .moveWindow(id: "w2", frame: original),
            .moveWindow(id: "w1", frame: original)])
        let result = await WorkspaceLaunchExecutor.applyCooperatively(plan, snapshot: snapshot, adapter: adapter)
        XCTAssertEqual(result.completed, 1)
        XCTAssertEqual(result.recovery.windowIDs, ["w1", "w2"])
        XCTAssertEqual(adapter.moves.count, 2)
        let restored = await WorkspaceLaunchExecutor.restoreCooperatively(result.recovery, adapter: adapter)
        XCTAssertEqual(restored.completed, 1)
        XCTAssertEqual(restored.recovery.windowIDs, ["w2"])
    }

    func testChainedMovesRestoreTheOriginalFrameOnce() async {
        let adapter = FakeAdapter()
        let snapshot = WorkspaceSnapshot(windows: [WorkspaceWindow(id: "w", bundleID: "app", frame: original)])
        let plan = WorkspacePlan(operations: [
            .moveWindow(id: "w", frame: WorkspaceRect(x: 0, y: 0, width: 500, height: 400)),
            .moveWindow(id: "w", frame: WorkspaceRect(x: 200, y: 200, width: 500, height: 400))
        ])
        let result = await WorkspaceLaunchExecutor.apply(plan, snapshot: snapshot, adapter: adapter)
        XCTAssertEqual(result.completed, 2)
        XCTAssertEqual(result.movedWindowIDs, ["w"], "Diagnostics count a window once even when several steps move it")
        XCTAssertEqual(result.recovery.windows.count, 1)
        let restore = await WorkspaceLaunchExecutor.restore(result.recovery, adapter: adapter)
        XCTAssertTrue(restore.recovery.isEmpty)
        XCTAssertEqual(adapter.moves.last?.1, original)
        XCTAssertEqual(adapter.moves.count, 3)
    }

    func testFailureStopsTheChainAndKeepsAttemptedMoveRecoverable() async {
        let adapter = FakeAdapter()
        adapter.failingWindow = "w"
        let snapshot = WorkspaceSnapshot(windows: [WorkspaceWindow(id: "w", bundleID: "app", frame: original)],
            applications: [WorkspaceApplication(bundleID: "other")])
        let result = await WorkspaceLaunchExecutor.apply(WorkspacePlan(operations: [
            .moveWindow(id: "w", frame: WorkspaceRect(x: 0, y: 0, width: 500, height: 400)),
            .hideApp(bundleID: "other")
        ]), snapshot: snapshot, adapter: adapter)
        XCTAssertEqual(result.completed, 0)
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.recovery.windows.first?.frame, original)
        XCTAssertTrue(adapter.hides.isEmpty)
        let failedRestore = await WorkspaceLaunchExecutor.restore(result.recovery, adapter: adapter)
        XCTAssertEqual(failedRestore.recovery.windows.count, 1)
        adapter.failingWindow = nil
        let retry = await WorkspaceLaunchExecutor.restore(failedRestore.recovery, adapter: adapter)
        XCTAssertTrue(retry.recovery.isEmpty)
        XCTAssertEqual(retry.completed, 1)
    }

    func testRestoreOnlyUnhidesAppsChangedByThisRun() async {
        let adapter = FakeAdapter()
        let snapshot = WorkspaceSnapshot(applications: [
            WorkspaceApplication(bundleID: "before", isHidden: true),
            WorkspaceApplication(bundleID: "changed", isHidden: false)
        ])
        let result = await WorkspaceLaunchExecutor.apply(WorkspacePlan(operations: [.hideApp(bundleID: "before"), .hideApp(bundleID: "changed")]), snapshot: snapshot, adapter: adapter)
        XCTAssertEqual(adapter.hides, ["changed"])
        XCTAssertEqual(result.recovery.hiddenBundleIDs, ["changed"])
        _ = await WorkspaceLaunchExecutor.restore(result.recovery, adapter: adapter)
        XCTAssertEqual(adapter.unhides, ["changed"])
    }

    func testMissingAndInvalidWindowNeverReachesAdapter() async {
        let adapter = FakeAdapter()
        let result = await WorkspaceLaunchExecutor.apply(WorkspacePlan(operations: [.moveWindow(id: "missing", frame: original)]), snapshot: WorkspaceSnapshot(), adapter: adapter)
        XCTAssertTrue(adapter.moves.isEmpty)
        XCTAssertTrue(result.recovery.isEmpty)
        XCTAssertEqual(result.failures.count, 1)
    }
}

extension WorkspaceLaunchExecutorTests {
    func testExplicitResetClearsLinksEvenWhenRoutineDefinitionsAreUnreadable() {
        let settings = AppSettings.shared
        let savedVoice = settings.voiceLaunchJSON
        let savedWorkspaces = settings.workspaceLaunchJSON
        defer { settings.voiceLaunchJSON = savedVoice; settings.workspaceLaunchJSON = savedWorkspaces }
        var voice = VoiceLaunchConfig.empty
        XCTAssertNil(VoiceWorkspaceLink.add(workspaceId: "missing", name: "Writing", phrase: "Start writing", id: "linked", to: &voice))
        voice.commands.append(VoiceCommand(id: "card", name: "Workspace", pattern: "Workspace {workspace}", steps: [.init(kind: .runWorkspace, text: "{workspace}")]))
        var mixed = VoiceWorkspaceLink.draft(workspaceId: "missing", name: "Mixed", phrase: "Mixed", id: "mixed")
        mixed.steps.append(.init(kind: .typeText, text: "Retained"))
        voice.commands.append(mixed)
        settings.voiceLaunchJSON = voice.encoded()
        settings.workspaceLaunchJSON = "unreadable synthetic definitions"
        let controller = WorkspaceLaunchController(adapter: FakeAdapter(), settings: settings)
        controller.resetSavedRoutines()
        XCTAssertEqual(settings.workspaceLaunch, .empty)
        XCTAssertEqual(settings.voiceLaunch.commands.map(\.id), ["card", "mixed"])
        XCTAssertEqual(settings.voiceLaunch.commands[1].steps.map(\.kind), [.typeText])
    }
}
