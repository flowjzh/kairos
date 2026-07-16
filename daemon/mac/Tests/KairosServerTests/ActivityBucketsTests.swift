import Testing
import KairosCore
import KairosStore
@testable import KairosServer

/// Menu placement, fully derived from the focus/blur log (ADR 37). One visible
/// list is split into Ongoing / Upcoming / Recent. "Ended" is manual-only.
@Suite struct ActivityBucketsTests {
    let now = 100.0

    func manual(_ id: Int64, _ title: String = "Meeting") -> ActivityRecord {
        ActivityRecord(id: id, source: "manual", externalId: nil, project: nil,
                       title: title, metadata: nil, manual: true, displayName: "Manual")
    }
    func auto(_ id: Int64) -> ActivityRecord {
        ActivityRecord(id: id, source: "pty", externalId: nil, project: nil,
                       title: nil, metadata: nil, manual: false, displayName: "Terminal")
    }
    func ev(_ id: Int64, _ ts: Double, _ act: Int64, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: act, kind: kind)
    }

    @Test func futureManualIsUpcoming() {
        let r = ActivityBuckets.partition(
            visible: [manual(1)],
            events: [ev(1, 200, 1, .focus), ev(2, 300, 1, .blur)], now: now)
        #expect(r.upcoming.map(\.id) == [1])
        #expect(r.upcoming.first?.start == 200)
        #expect(r.ongoing.isEmpty && r.recent.isEmpty)
    }

    @Test func ongoingManualIsOngoing() {
        // started (focus past), end still ahead.
        let r = ActivityBuckets.partition(
            visible: [manual(2)],
            events: [ev(1, 50, 2, .focus), ev(2, 200, 2, .blur)], now: now)
        #expect(r.ongoing.map(\.id) == [2])
        #expect(r.upcoming.isEmpty && r.recent.isEmpty)
    }

    @Test func endedManualIsRecent() {
        // both focus and blur in the past.
        let r = ActivityBuckets.partition(
            visible: [manual(3)],
            events: [ev(1, 10, 3, .focus), ev(2, 50, 3, .blur)], now: now)
        #expect(r.recent.map(\.id) == [3])
        #expect(r.ongoing.isEmpty && r.upcoming.isEmpty)
    }

    @Test func backdropWithoutEndIsOngoing() {
        // a live manual backdrop (focus past, no blur).
        let r = ActivityBuckets.partition(
            visible: [manual(4)], events: [ev(1, 10, 4, .focus)], now: now)
        #expect(r.ongoing.map(\.id) == [4])
    }

    @Test func autoWithPastBlurStaysOngoing() {
        // an auto activity's blur is transient (terminal unfocused), not an end —
        // it stays Ongoing while visible (exited autos are archived, not here).
        let r = ActivityBuckets.partition(
            visible: [auto(5)], events: [ev(1, 10, 5, .focus), ev(2, 50, 5, .blur)], now: now)
        #expect(r.ongoing.map(\.id) == [5])
        #expect(r.recent.isEmpty)
    }

    @Test func upcomingSortedByStart() {
        let r = ActivityBuckets.partition(
            visible: [manual(6), manual(7)],
            events: [ev(1, 300, 6, .focus), ev(2, 150, 7, .focus)], now: now)
        #expect(r.upcoming.map(\.id) == [7, 6])   // 150 before 300
    }
}
