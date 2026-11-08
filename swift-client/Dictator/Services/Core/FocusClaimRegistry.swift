import Foundation

// Tracks which Edge last claimed OS focus, so a finished transcription can be
// inserted wherever the user is actually looking rather than always back on
// whichever Edge pressed the hotkey. Claims are ordered by the Core's own
// receipt clock (the `at:` the SessionBroker passes in from `clock()`), never
// by an Edge's wall clock — clocks across machines aren't trusted to agree.
//
// Two kinds of claim, deliberately not treated as equally trustworthy — see
// `FocusClaimKind` and `freshest(connected:)`.
final class FocusClaimRegistry {
    /// `.keystroke` claims (`EdgeMessage.focusClaim`, driven by
    /// `FocusClaimDetector`'s click/keyDown probe) are ambiguous: Universal
    /// Control can deliver the same physical keyDown to both Macs' event
    /// taps (a shared keyboard means the non-pointer Mac can see, and claim
    /// focus for, a keystroke that never happened there), so two edges can
    /// race to claim the same burst of typing and whichever's message the
    /// Core happens to receive last wins — effectively at random.
    ///
    /// `.pointer` claims (`EdgeMessage.pointerPresence`) don't have this
    /// problem: only the Mac that currently owns the on-screen pointer ever
    /// receives `mouseMoved`/`leftMouseDown` from its own tap (hovering
    /// the non-pointer Mac fires nothing there). So whenever at least one
    /// eligible connected edge has reported pointer presence, `freshest`
    /// trusts pointer claims exclusively. Session routing also limits the
    /// receipt time and which Macs may redirect through keystroke claims.
    enum FocusClaimKind: Equatable {
        case pointer
        case keystroke
    }

    private struct Claim {
        var appBundleId: String?
        var receivedAt: TimeInterval
        /// Breaks ties between claims that land on the same `receivedAt`
        /// (a real possibility with a coarse or mocked clock): later `record`
        /// call wins.
        var sequence: Int
        var kind: FocusClaimKind
    }

    /// One slot per (edge, kind). The kinds must not share a slot: typing on
    /// the pointer Mac produces a keystroke claim there, and if that
    /// overwrote the same edge's pointer claim, the other edge's stale
    /// pointer claim (from before the pointer crossed) would be the only
    /// `.pointer` entry left and would win — re-creating the bug this
    /// registry exists to fix. A keystroke claim therefore never erases a
    /// pointer claim, and vice versa.
    private var claims: [EdgeID: [FocusClaimKind: Claim]] = [:]
    private var nextSequence = 0

    /// Focus reports default to keystroke priority. Pointer presence and
    /// a lone settled press are stronger evidence and pass `.pointer`.
    func record(edge: EdgeID, appBundleId: String?, at time: TimeInterval, kind: FocusClaimKind = .keystroke) {
        nextSequence += 1
        claims[edge, default: [:]][kind] = Claim(appBundleId: appBundleId, receivedAt: time, sequence: nextSequence, kind: kind)
    }

    /// Pointer-only reports locate the Mac but contain no app identity.
    /// Keep the app from that Mac's latest focus report, never another Mac.
    func appBundleID(for edge: EdgeID) -> String? {
        claims[edge]?[.keystroke]?.appBundleId
    }

    func remove(edge: EdgeID) {
        claims.removeValue(forKey: edge)
    }

    /// Filter by connected Macs, receipt time and eligible keystroke reporters
    /// before choosing the freshest pointer, or otherwise the freshest keystroke.
    /// Without session filters, pointer claims of any age take priority.
    func freshest(connected: Set<EdgeID>, since: TimeInterval = -.infinity,
                  keystrokeEdges: Set<EdgeID>? = nil) -> EdgeID? {
        let candidates: [(edge: EdgeID, claim: Claim)] = claims
            .filter { connected.contains($0.key) }
            .flatMap { edge, byKind in byKind.values.map { (edge, $0) } }
        let eligible = candidates.filter {
            $0.claim.receivedAt >= since && ($0.claim.kind == .pointer || keystrokeEdges?.contains($0.edge) != false)
        }
        let pointerCandidates = eligible.filter { $0.claim.kind == .pointer }
        let pool = pointerCandidates.isEmpty ? eligible : pointerCandidates
        let freshest = pool.max { ($0.claim.receivedAt, $0.claim.sequence) < ($1.claim.receivedAt, $1.claim.sequence) }
        return freshest?.edge
    }

    /// The edge's most recent claim of either kind.
    func claim(for edge: EdgeID) -> (appBundleId: String?, receivedAt: TimeInterval)? {
        guard let c = claims[edge]?.values.max(by: { ($0.receivedAt, $0.sequence) < ($1.receivedAt, $1.sequence) }) else { return nil }
        return (c.appBundleId, c.receivedAt)
    }
}
