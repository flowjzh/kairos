import Testing
@testable import KairosCore

/// ADR 21 — one reducer defines afk/pause spans, the current owner, and open
/// activities together, so the menu, `GlobalSpans`, and `OwnerPredictor` can't
/// drift apart.
@Suite
struct GlobalStateTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    @Test
    func pairsAfkAndPauseSpans() {
        let events = [
            ev(1, 0, nil, .afkOn), ev(2, 10, nil, .afkOff),
            ev(3, 20, nil, .pauseOn), ev(4, 30, nil, .pauseOff),
        ]
        let s = GlobalState.reduce(events: events, to: 100)
        #expect(s.afk == [Interval(start: 0, end: 10)])
        #expect(s.pause == [Interval(start: 20, end: 30)])
        #expect(s.isAfk == false)
        #expect(s.isPaused == false)
    }

    @Test
    func openAfkSpanExtendsToRangeEndAndFlagsAfk() {
        let s = GlobalState.reduce(events: [ev(1, 50, nil, .afkOn)], to: 100)
        #expect(s.afk == [Interval(start: 50, end: 100)])
        #expect(s.isAfk == true)
    }

    @Test
    func aiStopClaimsOwner() {
        // M2 extension: an ai_stop makes its session the owner (human now working).
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 10, 1, .aiSubmit), ev(3, 20, 1, .aiStop)]
        #expect(GlobalState.reduce(events: events, to: 100).owner == 1)
    }

    @Test
    func aiSubmitDoesNotChangeOwner() {
        // After you submit, the agent grinds but the session is still "yours".
        let events = [ev(1, 0, 2, .aiStop), ev(2, 10, 2, .aiSubmit)]
        #expect(GlobalState.reduce(events: events, to: 100).owner == 2)
    }

    @Test
    func closeReleasesOwnerAndOpenSet() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 10, 1, .activityClose)]
        let s = GlobalState.reduce(events: events, to: 100)
        #expect(s.owner == nil)
        #expect(s.openActivities.isEmpty)
    }

    @Test
    func closeRestoresPreviousStillOpenOwner() {
        // A second activity opens (owner) then closes; ownership reverts to the
        // first, still-open activity — not nil. docs/06 §6: owner is the latest
        // claim whose activity has no later close, so closing the meeting only
        // invalidates the meeting's own claim.
        let events = [
            ev(1, 0, 6, .activityOpen),    // claude session → owner 6
            ev(2, 10, 6, .aiStop),         // still owner 6
            ev(3, 20, 7, .activityOpen),   // meeting opens → owner 7
            ev(4, 30, 7, .activityClose),  // meeting closes → back to 6
        ]
        let s = GlobalState.reduce(events: events, to: 100)
        #expect(s.owner == 6)
        #expect(s.openActivities == [6])
    }

    @Test
    func tracksOpenActivities() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 5, 2, .activityOpen),
            ev(3, 10, 1, .activityClose),
        ]
        #expect(GlobalState.reduce(events: events, to: 100).openActivities == [2])
    }

    @Test
    func afkAndPauseDoNotClearOwner() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 5, nil, .afkOn), ev(3, 8, nil, .pauseOn),
        ]
        let s = GlobalState.reduce(events: events, to: 100)
        #expect(s.owner == 1)
        #expect(s.isAfk == true)
        #expect(s.isPaused == true)   // both spans open concurrently — no drift
    }
}
