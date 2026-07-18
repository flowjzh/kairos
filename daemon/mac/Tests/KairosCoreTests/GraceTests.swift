import Testing
@testable import KairosCore

/// Blur-grace absorb + pending (ADR 39): an auto activity's brief blur-to-void
/// with a same-activity re-focus within grace is absorbed; manual blurs never are.
@Suite
struct GraceTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    private let grace: Double = 120

    // MARK: absorbedBlurIds

    @Test
    func absorbsSameActivityRefocusWithinGrace() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 20, 1, .focus)]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [])
        #expect(absorbed == [2])
    }

    @Test
    func keepsBlurWhenRefocusBeyondGrace() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 200, 1, .focus)]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [])
        #expect(absorbed.isEmpty)
    }

    @Test
    func keepsBlurWhenAnotherActivityTakesFocus() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 15, 2, .focus), ev(4, 20, 1, .focus)]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [])
        #expect(absorbed.isEmpty)  // B intervened at 15 → blur@10 stands
    }

    @Test
    func manualBlurIsNeverAbsorbed() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 20, 1, .focus)]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [1])
        #expect(absorbed.isEmpty)
    }

    @Test
    func absorbsEachEligibleBlurInAChain() {
        // focus A@0, blur@10, refocus@20 (absorb), blur@200, refocus@210 (absorb).
        let events = [
            ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 20, 1, .focus),
            ev(4, 200, 1, .blur), ev(5, 210, 1, .focus),
        ]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [])
        #expect(absorbed == [2, 4])
    }

    @Test
    func outOfOrderBlurIsANoop() {
        // A focused; a stray blur(B) is a no-op; A's own blur is what absorbs.
        let events = [ev(1, 0, 1, .focus), ev(2, 30, 2, .blur), ev(3, 100, 1, .blur), ev(4, 110, 1, .focus)]
        let absorbed = Grace.absorbedBlurIds(events: events, grace: grace, manualIds: [])
        #expect(absorbed == [3])
    }

    // MARK: pending

    @Test
    func pendingWithinGraceWithNoRefocus() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur)]
        let pending = Grace.pending(events: events, to: 20, grace: grace, manualIds: [])
        #expect(pending == .init(activityId: 1, blurTs: 10))
    }

    @Test
    func pendingNilAfterRefocus() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 20, 1, .focus)]
        #expect(Grace.pending(events: events, to: 30, grace: grace, manualIds: []).map(\.activityId) == nil)
    }

    @Test
    func pendingNilBeyondGrace() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur)]
        #expect(Grace.pending(events: events, to: 200, grace: grace, manualIds: []) == nil)
    }

    @Test
    func pendingNilWhenAnotherActivityIsFocused() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur), ev(3, 20, 2, .focus)]
        #expect(Grace.pending(events: events, to: 30, grace: grace, manualIds: []) == nil)
    }

    @Test
    func pendingNeverManual() {
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .blur)]
        #expect(Grace.pending(events: events, to: 20, grace: grace, manualIds: [1]) == nil)
    }
}
