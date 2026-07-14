import Testing
@testable import KairosCore

@Suite
struct OwnerPredictorTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    @Test
    func openClaims() {
        #expect(OwnerPredictor.predict(events: [ev(1, 0, 1, .activityOpen)]) == 1)
    }

    @Test
    func latestOpenWins() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, 2, .activityOpen)]
        #expect(OwnerPredictor.predict(events: events) == 2)
    }

    @Test
    func closeReleases() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, 1, .activityClose)]
        #expect(OwnerPredictor.predict(events: events) == nil)
    }

    @Test
    func afkDoesNotClearOwner() {
        // afk is a temporary display state; the open activity stays the owner.
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, nil, .afkOn)]
        #expect(OwnerPredictor.predict(events: events) == 1)
    }

    @Test
    func pauseDoesNotClearOwner() {
        // Pause/resume is temporary; the activity persists as the owner.
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, nil, .pauseOn), ev(3, 2, nil, .pauseOff)]
        #expect(OwnerPredictor.predict(events: events) == 1)
    }

    @Test
    func forceOwnerOverrides() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, 2, .forceOwner)]
        #expect(OwnerPredictor.predict(events: events) == 2)
    }

    @Test
    func reopenAfterClose() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 1, 1, .activityClose), ev(3, 2, 2, .activityOpen)]
        #expect(OwnerPredictor.predict(events: events) == 2)
    }
}
