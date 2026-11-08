import AppKit
import Foundation

// Wiring: EdgeRuntime creates one detector, sets
// `hotkeyService.onFocusActivity = { detector.noteActivity($0) }` and
// `detector.onClaim = { send(.focusClaim(appBundleId: $0)) }`.

/// Detects "the user just clicked or typed into an editable field on this
/// Mac" and turns bursts of that activity into a debounced, rate-limited
/// focus claim. The Core resolves the freshest claim across
/// Edges at insertion time — this class only decides when this Edge should
/// assert one. `HotkeyService.onFocusActivity` fires `noteActivity` from the
/// tap thread; every bit of AX work (the probe itself) happens off that
/// thread, hopped onto `queue`, so the tap callback is never blocked.
final class FocusClaimDetector {
    /// Rolling window for the claims-per-second throttle below.
    private static let throttleWindow: TimeInterval = 1.0

    private let probe: () -> String??
    private let queue: DispatchQueue
    private let clock: () -> TimeInterval
    private let debounce: TimeInterval
    private let maxClaimsPerSecond: Int

    /// Called on `queue` whenever the probe confirms an editable field is
    /// focused — never for a non-editable focus.
    var onClaim: ((_ appBundleId: String?) -> Void)?

    /// The one outstanding debounced probe. Replaced (not appended to) on
    /// every activity — that's the debounce collapse.
    private var pendingProbe: DispatchWorkItem?
    /// Timestamps (by `clock`) of claims emitted within the current rolling
    /// window, oldest first — the throttle's bookkeeping.
    private var claimTimestamps: [TimeInterval] = []

    init(
        probe: @escaping () -> String?? = FocusClaimDetector.defaultProbe,
        queue: DispatchQueue = DispatchQueue(label: "dev.noamlitt.dictation.focus-claim", qos: .utility),
        clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        debounce: TimeInterval = 0.15,
        maxClaimsPerSecond: Int = 4
    ) {
        self.probe = probe
        self.queue = queue
        self.clock = clock
        self.debounce = debounce
        self.maxClaimsPerSecond = maxClaimsPerSecond
    }

    /// Callable from the tap thread — just hops to `queue` and schedules (or
    /// reschedules) a debounced probe there. No AX work happens on this call.
    func noteActivity(_ kind: FocusActivityKind) {
        queue.async { [weak self] in
            self?.scheduleProbe()
        }
    }

    /// Cancels any pending probe without running it. For a mode switch or
    /// teardown where a stale claim would be worse than no claim.
    func reset() {
        queue.async { [weak self] in
            self?.pendingProbe?.cancel()
            self?.pendingProbe = nil
        }
    }

    /// `CaretLocator.textInsertionSnapshot()` is the same AX probe
    /// `PasteService` uses to verify an insertion, so "editable field
    /// focused" here means exactly what it means there. Outer optional:
    /// nil when nothing editable is focused (no claim). Inner optional:
    /// the frontmost app's bundle id, which can itself be nil.
    static func defaultProbe() -> String?? {
        guard CaretLocator.textInsertionSnapshot() != nil else { return nil }
        return .some(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    // MARK: - Private (queue-confined)

    /// Runs on `queue`. Collapses activity bursts within `debounce` into one
    /// probe by replacing any still-pending one, and never schedules earlier
    /// than the throttle allows — computed as `max(now + debounce,
    /// nextAllowedTime)` so the last activity in a throttled burst still
    /// produces a claim once the window opens, rather than being dropped
    /// along with the others.
    private func scheduleProbe() {
        pendingProbe?.cancel()

        let now = clock()
        prune(asOf: now)
        let nextAllowedTime = claimTimestamps.count < maxClaimsPerSecond
            ? now
            : claimTimestamps[0] + Self.throttleWindow

        let fireAt = max(now + debounce, nextAllowedTime)
        let work = DispatchWorkItem { [weak self] in self?.runProbe() }
        pendingProbe = work
        queue.asyncAfter(deadline: .now() + max(0, fireAt - now), execute: work)
    }

    /// Runs on `queue`, off the tap thread — this is the only place the AX
    /// probe actually executes.
    private func runProbe() {
        pendingProbe = nil
        guard let bundleId = probe() else { return } // nothing editable focused: no claim

        let now = clock()
        prune(asOf: now)
        claimTimestamps.append(now)
        onClaim?(bundleId)
    }

    private func prune(asOf now: TimeInterval) {
        claimTimestamps.removeAll { now - $0 >= Self.throttleWindow }
    }
}
