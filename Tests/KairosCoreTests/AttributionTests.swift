import Testing
@testable import KairosCore

@Suite
struct AttributionTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    @Test
    func singleExplicitWindow() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 3600, 1, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 7200)
        #expect(segs == [Segment(activityId: 1, start: 0, end: 3600, seconds: 3600, rule: "explicit")])
    }

    @Test
    func pauseHolesExplicit() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 1800, nil, .pauseOn),
            ev(3, 2400, nil, .pauseOff),
            ev(4, 3600, 1, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 7200)
        #expect(segs.count == 2)
        #expect(segs.contains(Segment(activityId: 1, start: 0, end: 1800, seconds: 1800, rule: "explicit")))
        #expect(segs.contains(Segment(activityId: 1, start: 2400, end: 3600, seconds: 1200, rule: "explicit")))
    }

    @Test
    func afkDoesNotHoleExplicit() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 1200, nil, .afkOn),
            ev(3, 2400, nil, .afkOff),
            ev(4, 3600, 1, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 7200)
        #expect(segs == [Segment(activityId: 1, start: 0, end: 3600, seconds: 3600, rule: "explicit")])
    }

    @Test
    func concurrentExplicitsBothKept() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 3600, 1, .activityClose),
            ev(3, 900, 2, .activityOpen),
            ev(4, 2700, 2, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 7200).sorted { $0.activityId < $1.activityId }
        #expect(segs.count == 2)
        #expect(segs[0] == Segment(activityId: 1, start: 0, end: 3600, seconds: 3600, rule: "explicit"))
        #expect(segs[1] == Segment(activityId: 2, start: 900, end: 2700, seconds: 1800, rule: "explicit"))
    }

    @Test
    func clipsToRange() {
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 3600, 1, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 1800, to: 2400)
        #expect(segs == [Segment(activityId: 1, start: 1800, end: 2400, seconds: 600, rule: "explicit")])
    }

    @Test
    func openActivityBilledToRangeEnd() {
        let events = [ev(1, 0, 1, .activityOpen)]
        let segs = Attribution.compute(events: events, from: 0, to: 1800)
        #expect(segs == [Segment(activityId: 1, start: 0, end: 1800, seconds: 1800, rule: "explicit")])
    }

    @Test
    func activityOutsideRangeYieldsNothing() {
        let events = [
            ev(1, 3600, 1, .activityOpen),
            ev(2, 7200, 1, .activityClose),
        ]
        let segs = Attribution.compute(events: events, from: 0, to: 1800)
        #expect(segs.isEmpty)
    }

    @Test
    func holingRuleStraddleVsEmbedded() {
        // docs/04 worked example: meeting [2:00,3:00] (120..180).
        let meeting = Interval(start: 120, end: 180)
        // ai straddling the boundary [1:50,2:10] (110..130) → not contained → hole holds
        let straddle = Interval(start: 110, end: 130)
        #expect(!meeting.contains(straddle))
        #expect(Interval.subtract(straddle, [meeting]) == [Interval(start: 110, end: 120)])
        // ai fully embedded [2:10,2:15] (130..135) → contained → concurrent (both kept)
        let embedded = Interval(start: 130, end: 135)
        #expect(meeting.contains(embedded))
    }
}
