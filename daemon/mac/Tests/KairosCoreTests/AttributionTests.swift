import Testing
@testable import KairosCore

/// Focus-driven attribution (M4p3): base = focus intervals, minus the activity's
/// own ai grind, minus global afk/pause.
@Suite
struct AttributionTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    /// Total seconds attributed to an activity across all its segments.
    private func seconds(_ segments: [Segment], _ activityId: Int64) -> Double {
        segments.filter { $0.activityId == activityId }.reduce(0) { $0 + $1.seconds }
    }

    @Test
    func plainFocusInterval() {
        let events = [ev(1, 0, 1, .focus), ev(2, 100, 1, .blur)]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        #expect(seconds(segs, 1) == 100)
    }

    @Test
    func aiGrindIsDeducted_andTailCounts() {
        // focus [0,100]; grind [10,20]; after ai_stop you keep reading → counts.
        let events = [
            ev(1, 0, 1, .focus),
            ev(2, 10, 1, .aiSubmit),
            ev(3, 20, 1, .aiStop),
            ev(4, 100, 1, .blur),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        #expect(seconds(segs, 1) == 90)                             // 100 − 10 grind
        #expect(segs.contains { $0.start == 20 && $0.end == 100 })  // tail survives
    }

    @Test
    func openGrindDeductedToRangeEnd() {
        // submit with no stop → grind runs to `to`; blur closes focus at 100.
        let events = [ev(1, 0, 1, .focus), ev(2, 40, 1, .aiSubmit), ev(3, 100, 1, .blur)]
        let segs = Attribution.compute(events: events, from: 0, to: 100)
        #expect(seconds(segs, 1) == 40)                             // [0,40] only
    }

    @Test
    func switchingMovesTheSinglePointer() {
        let events = [ev(1, 0, 1, .focus), ev(2, 50, 2, .focus), ev(3, 100, 2, .blur)]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        #expect(seconds(segs, 1) == 50)                             // A ends at focus(B)
        #expect(seconds(segs, 2) == 50)
    }

    @Test
    func blurClearsOnlyCurrentHolder() {
        // A focused; a stray blur(B) is a no-op; A stays until its own blur.
        let events = [ev(1, 0, 1, .focus), ev(2, 30, 2, .blur), ev(3, 100, 1, .blur)]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        #expect(seconds(segs, 1) == 100)
        #expect(seconds(segs, 2) == 0)
    }

    @Test
    func afkHolesTheFocusInterval() {
        let events = [
            ev(1, 0, 1, .focus),
            ev(2, 30, nil, .afkOn),
            ev(3, 60, nil, .afkOff),
            ev(4, 100, 1, .blur),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        #expect(seconds(segs, 1) == 70)                             // 100 − 30 afk
    }

    @Test
    func pauseHolesTheFocusInterval() {
        let events = [
            ev(1, 0, 1, .focus),
            ev(2, 40, nil, .pauseOn),
            ev(3, 50, nil, .pauseOff),
            ev(4, 100, 1, .blur),
        ]
        #expect(seconds(Attribution.compute(events: events, from: 0, to: 1000), 1) == 90)
    }

    @Test
    func stillFocusedTailExtendsToRangeEnd() {
        let segs = Attribution.compute(events: [ev(1, 0, 1, .focus)], from: 0, to: 100)
        #expect(seconds(segs, 1) == 100)
    }

    @Test
    func clipsToRange() {
        let events = [ev(1, 0, 1, .focus), ev(2, 100, 1, .blur)]
        #expect(seconds(Attribution.compute(events: events, from: 50, to: 1000), 1) == 50)
    }

    @Test
    func noFocusNoSegments() {
        let events = [ev(1, 0, 1, .aiSubmit), ev(2, 20, 1, .aiStop)]
        #expect(Attribution.compute(events: events, from: 0, to: 1000).isEmpty)
    }

    @Test
    func afkSubmitBreak() {
        // A submit inside an (offline) afk span breaks it at the submit instant.
        let events = [
            ev(1, 0, 1, .focus),
            ev(2, 20, nil, .afkOn),
            ev(3, 40, 1, .aiSubmit),   // proves presence → afk ends at 40
            ev(4, 60, nil, .afkOff),
            ev(5, 100, 1, .blur),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 1000)
        // afk holes [20,40]; grind from the submit runs to focus-end 100 →
        // [40,100] is grind-holed away; surviving = [0,20].
        #expect(seconds(segs, 1) == 20)
    }
}
