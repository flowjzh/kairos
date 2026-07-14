import Testing
@testable import KairosCore

/// docs/04 worked examples for ai attribution at the `Attribution.compute`
/// level: signature dispatch, afk/pause holing (with afk-submit-break), and
/// the explicit-vs-ai holing rule (straddle punches, embedded is concurrent).
@Suite
struct AttributionAiTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    private func ai(_ segs: [Segment]) -> [Segment] { segs.filter { $0.rule == "ai" }.sorted { $0.start < $1.start } }

    @Test
    func singleSessionResearchAndLunch() {
        // docs/04: ai_stop 10:00, afk 10:15–10:40, ai_submit 10:42
        //  → A = [10:00–10:15] ∪ [10:40–10:42] (afk holes the window).
        let events = [
            ev(1, 36000, 1, .aiStop),
            ev(2, 36900, nil, .afkOn),
            ev(3, 38400, nil, .afkOff),
            ev(4, 38520, 1, .aiSubmit),
        ]
        let segs = ai(Attribution.compute(events: events, from: 0, to: 100_000))
        #expect(segs == [
            Segment(activityId: 1, start: 36000, end: 36900, seconds: 900, rule: "ai"),
            Segment(activityId: 1, start: 38400, end: 38520, seconds: 120, rule: "ai"),
        ])
    }

    @Test
    func straddlingAiPunchedByMeeting() {
        // ai [1:50,2:10] straddles meeting [2:00,3:00] → ai ⊄ meeting → holed:
        //  ai = [1:50,2:00]; meeting = [2:00,3:00].
        let events = [
            ev(1, 6600, 1, .activityOpen),   // ai session
            ev(2, 7800, 1, .aiSubmit),       // window [6600,7800]
            ev(3, 7200, 2, .activityOpen),   // meeting
            ev(4, 10800, 2, .activityClose),
        ]
        let all = Attribution.compute(events: events, from: 0, to: 100_000)
        #expect(ai(all) == [Segment(activityId: 1, start: 6600, end: 7200, seconds: 600, rule: "ai")])
        #expect(all.contains(Segment(activityId: 2, start: 7200, end: 10800, seconds: 3600, rule: "explicit")))
    }

    @Test
    func embeddedAiConcurrentWithMeeting() {
        // ai [2:10,2:15] ⊆ meeting [2:00,3:00] → concurrent (both kept).
        let events = [
            ev(1, 7800, 1, .aiStop),         // ai session
            ev(2, 8100, 1, .aiSubmit),       // window [7800,8100]
            ev(3, 7200, 2, .activityOpen),   // meeting
            ev(4, 10800, 2, .activityClose),
        ]
        let all = Attribution.compute(events: events, from: 0, to: 100_000)
        #expect(ai(all) == [Segment(activityId: 1, start: 7800, end: 8100, seconds: 300, rule: "ai")])
        #expect(all.contains(Segment(activityId: 2, start: 7200, end: 10800, seconds: 3600, rule: "explicit")))
    }

    @Test
    func nestingAcrossTwoSessions() {
        // A stop@10, B stop@20, B submit@30, B stop@40, A submit@50.
        // A = [10,20] ∪ [30,50], B = [20,30].
        let events = [
            ev(1, 10, 1, .aiStop),
            ev(2, 20, 2, .aiStop),
            ev(3, 30, 2, .aiSubmit),
            ev(4, 40, 2, .aiStop),
            ev(5, 50, 1, .aiSubmit),
        ]
        let segs = ai(Attribution.compute(events: events, from: 0, to: 1000))
        #expect(segs.filter { $0.activityId == 1 } == [
            Segment(activityId: 1, start: 10, end: 20, seconds: 10, rule: "ai"),
            Segment(activityId: 1, start: 30, end: 50, seconds: 20, rule: "ai"),
        ])
        #expect(segs.filter { $0.activityId == 2 } == [
            Segment(activityId: 2, start: 20, end: 30, seconds: 10, rule: "ai"),
        ])
    }

    @Test
    func submitInsideAfkBreaksIt() {
        // A window [100,600]; a submit from session B at 300 lands inside the
        // afk [200,500] → afk breaks at 300, so A keeps [300,600].
        let events = [
            ev(1, 100, 1, .aiStop),
            ev(2, 200, nil, .afkOn),
            ev(3, 300, 2, .aiSubmit),        // B's submit, inside the afk
            ev(4, 500, nil, .afkOff),
            ev(5, 600, 1, .aiSubmit),        // closes A's window
        ]
        let segs = ai(Attribution.compute(events: events, from: 0, to: 1000)).filter { $0.activityId == 1 }
        #expect(segs == [
            Segment(activityId: 1, start: 100, end: 200, seconds: 100, rule: "ai"),
            Segment(activityId: 1, start: 300, end: 600, seconds: 300, rule: "ai"),
        ])
    }

    @Test
    func aiPausedIsHoled() {
        // pause holes ai just like explicit: window [0,100], pause [40,60] → [0,40]∪[60,100].
        let events = [
            ev(1, 0, 1, .aiStop),
            ev(2, 40, nil, .pauseOn),
            ev(3, 60, nil, .pauseOff),
            ev(4, 100, 1, .aiSubmit),
        ]
        let segs = ai(Attribution.compute(events: events, from: 0, to: 1000))
        #expect(segs == [
            Segment(activityId: 1, start: 0, end: 40, seconds: 40, rule: "ai"),
            Segment(activityId: 1, start: 60, end: 100, seconds: 40, rule: "ai"),
        ])
    }
}
