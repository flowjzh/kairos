import Testing
@testable import KairosCore

/// docs/04 §B — ai submit-anchored strategy. Windows are
/// `[activity_open | ai_stop, ai_submit]`; open tails are not counted;
/// ai-vs-ai overlaps resolve by submit-priority (earlier submit wins).
@Suite
struct AiSubmitStrategyTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    // MARK: Per-activity window extraction

    @Test
    func windowsFromOpenAndStops() {
        // open@0 → submit@10 (first prompt), grind, stop@20 → submit@30, grind,
        // stop@40 with no following submit = open tail (dropped).
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 10, 1, .aiSubmit),
            ev(3, 20, 1, .aiStop),
            ev(4, 30, 1, .aiSubmit),
            ev(5, 40, 1, .aiStop),
        ]
        let windows = AiSubmitStrategy.windows(activityId: 1, events: events, rangeEnd: 1000)
        #expect(windows == [
            AiWindow(activityId: 1, interval: Interval(start: 0, end: 10), submitTs: 10, forced: false),
            AiWindow(activityId: 1, interval: Interval(start: 20, end: 30), submitTs: 30, forced: false),
        ])
    }

    @Test
    func openTailAloneYieldsNothing() {
        // open→submit→stop, then no further submit: the trailing stop is an
        // open tail (dropped); only [open, submit] survives.
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 10, 1, .aiSubmit), ev(3, 20, 1, .aiStop)]
        #expect(AiSubmitStrategy.windows(activityId: 1, events: events, rangeEnd: 1000)
            == [AiWindow(activityId: 1, interval: Interval(start: 0, end: 10), submitTs: 10, forced: false)])
        // open with no submit at all → even the first window is an open tail.
        let noSubmit = [ev(1, 0, 1, .activityOpen)]
        #expect(AiSubmitStrategy.windows(activityId: 1, events: noSubmit, rangeEnd: 1000).isEmpty)
    }

    @Test
    func forceOwnerWindowToClose() {
        // force_owner@50 → window [50, activity_close@80]; wins ai-vs-ai.
        let events = [
            ev(1, 0, 1, .activityOpen),
            ev(2, 10, 1, .aiSubmit),
            ev(3, 50, 1, .forceOwner),
            ev(4, 80, 1, .activityClose),
        ]
        let windows = AiSubmitStrategy.windows(activityId: 1, events: events, rangeEnd: 1000)
        #expect(windows.contains(AiWindow(activityId: 1, interval: Interval(start: 50, end: 80), submitTs: 50, forced: true)))
    }

    // MARK: Cross-activity resolution (submit-priority / nesting)

    @Test
    func nestingRecoversLostWindow() {
        // docs/04 worked example: A stop t1, B stop t2, B submit t3, B stop t4, A submit t5.
        // A window [t1,t5], B window [t2,t3]; B submitted earlier → B owns overlap.
        // Result: A = [t1,t2] ∪ [t3,t5], B = [t2,t3].
        let a = AiWindow(activityId: 1, interval: Interval(start: 10, end: 50), submitTs: 50, forced: false)
        let b = AiWindow(activityId: 2, interval: Interval(start: 20, end: 30), submitTs: 30, forced: false)
        let claims = AiSubmitStrategy.resolve([a, b])
        let byActivity = Dictionary(grouping: claims, by: { $0.activityId }).mapValues { $0.map(\.interval).sorted { $0.start < $1.start } }
        #expect(byActivity[1] == [Interval(start: 10, end: 20), Interval(start: 30, end: 50)])
        #expect(byActivity[2] == [Interval(start: 20, end: 30)])
    }

    @Test
    func forceOwnerWinsOverEarlierSubmit() {
        // A forced window claims before any submit-anchored window regardless of submit ts.
        let forced = AiWindow(activityId: 1, interval: Interval(start: 20, end: 40), submitTs: 20, forced: true)
        let submit = AiWindow(activityId: 2, interval: Interval(start: 10, end: 30), submitTs: 30, forced: false)
        let claims = AiSubmitStrategy.resolve([forced, submit])
        let byActivity = Dictionary(grouping: claims, by: { $0.activityId }).mapValues { $0.map(\.interval).sorted { $0.start < $1.start } }
        #expect(byActivity[1] == [Interval(start: 20, end: 40)])
        #expect(byActivity[2] == [Interval(start: 10, end: 20)])   // trimmed by the forced claim
    }
}
