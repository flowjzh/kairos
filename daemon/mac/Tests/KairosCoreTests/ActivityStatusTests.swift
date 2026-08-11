import Testing
@testable import KairosCore

/// The three green-dot states, derived from the focus pointer + blur-grace.
/// `derive` is pure and self-correcting on time — the live edge cases
/// (grace expiry with no event) must resolve correctly from `now` alone.
@Suite
struct ActivityStatusTests {
    private let pending = Grace.Pending(activityId: 1, blurTs: 1_000_000)

    @Test func focusedWinsOverGracingAndIdle() {
        #expect(ActivityStatus.derive(focused: 1, pending: pending, id: 1, now: 1_000_000, grace: 60) == .focused)
    }

    @Test func gracingWhenPendingMatchesAndWithinGrace() {
        #expect(ActivityStatus.derive(focused: 2, pending: pending, id: 1, now: 1_000_030, grace: 60) == .gracing)
        #expect(ActivityStatus.derive(focused: nil, pending: pending, id: 1, now: 1_000_060, grace: 60) == .gracing)
    }

    @Test func idleWhenPendingIsAnotherActivity() {
        #expect(ActivityStatus.derive(focused: nil, pending: pending, id: 2, now: 1_000_010, grace: 60) == .idle)
    }

    @Test func graceExpiryFlipsToIdle_liveNow() {
        // pending still passed in, but `now` is past blurTs + grace → idle. This
        // is the key correctness property: a cached `pending` goes stale at
        // expiry and derive notices from `now` alone (no recompute, no timer).
        #expect(ActivityStatus.derive(focused: nil, pending: pending, id: 1, now: 1_000_061, grace: 60) == .idle)
    }

    @Test func zeroGraceNeverGracing() {
        // grace "off" (0) collapses gracing to idle — matches Grace.pending.
        #expect(ActivityStatus.derive(focused: nil, pending: pending, id: 1, now: 1_000_000, grace: 0) == .idle)
    }

    @Test func noFocusedNoPendingIsIdle() {
        #expect(ActivityStatus.derive(focused: nil, pending: nil, id: 1, now: 1_000_000, grace: 60) == .idle)
    }
}
