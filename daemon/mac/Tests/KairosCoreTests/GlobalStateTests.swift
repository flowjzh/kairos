import Testing
@testable import KairosCore

/// ADR 21 — one reducer defines afk/pause spans and the focused activity, so the
/// menu and the attribution deductions can't drift apart. Since M4p3 the focus
/// pointer (latest `focus`, `blur` clears only the holder) replaces the owner.
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
    func latestFocusWins() {
        let events = [ev(1, 0, 1, .focus), ev(2, 20, 2, .focus)]
        #expect(GlobalState.reduce(events: events, to: 100).focused == 2)
    }

    @Test
    func blurClearsOnlyTheHolder() {
        // A focused; a stray blur(B) is a no-op; then blur(A) clears to none.
        let a = [ev(1, 0, 1, .focus), ev(2, 10, 2, .blur)]
        #expect(GlobalState.reduce(events: a, to: 100).focused == 1)
        let b = a + [ev(3, 20, 1, .blur)]
        #expect(GlobalState.reduce(events: b, to: 100).focused == nil)
    }

    @Test
    func futureFocusLightsUpOnlyAtItsTime() {
        // A meeting scheduled for ts=200 must not focus at now=100; at 200 it does.
        let events = [ev(1, 200, 7, .focus)]
        #expect(GlobalState.reduce(events: events, to: 100).focused == nil)
        #expect(GlobalState.reduce(events: events, to: 200).focused == 7)
    }

    @Test
    func aiEventsDoNotChangeFocus() {
        // Only focus/blur move the pointer; ai_submit/ai_stop are deductions.
        let events = [ev(1, 0, 1, .focus), ev(2, 10, 1, .aiSubmit), ev(3, 20, 1, .aiStop)]
        #expect(GlobalState.reduce(events: events, to: 100).focused == 1)
    }

    @Test
    func afkAndPauseDoNotClearFocus() {
        let events = [
            ev(1, 0, 1, .focus),
            ev(2, 5, nil, .afkOn), ev(3, 8, nil, .pauseOn),
        ]
        let s = GlobalState.reduce(events: events, to: 100)
        #expect(s.focused == 1)
        #expect(s.isAfk == true)
        #expect(s.isPaused == true)   // both spans open concurrently — no drift
    }
}
