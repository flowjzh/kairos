import Testing
import KairosCore
import KairosStore
@testable import KairosServer

/// Time-derived menu placement (bug: a future/ongoing timed meeting is stored
/// `stopped` at creation, so state-column placement wrongly dumped it in Recent).
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

    @Test func futureTimedMeetingIsUpcomingNotRecent() {
        // stored stopped at creation, focus/blur both in the future.
        let r = ActivityBuckets.partition(
            active: [], stopped: [manual(1)],
            events: [ev(1, 200, 1, .focus), ev(2, 300, 1, .blur)], now: now)
        #expect(r.upcoming.map(\.id) == [1])
        #expect(r.upcoming.first?.start == 200)
        #expect(r.recent.isEmpty && r.active.isEmpty)
    }

    @Test func ongoingTimedMeetingIsActiveNotRecent() {
        // started (focus in past), end still ahead → running.
        let r = ActivityBuckets.partition(
            active: [], stopped: [manual(2)],
            events: [ev(1, 50, 2, .focus), ev(2, 200, 2, .blur)], now: now)
        #expect(r.active.map(\.id) == [2])
        #expect(r.upcoming.isEmpty && r.recent.isEmpty)
    }

    @Test func endedTimedMeetingIsRecent() {
        let r = ActivityBuckets.partition(
            active: [], stopped: [manual(3)],
            events: [ev(1, 10, 3, .focus), ev(2, 50, 3, .blur)], now: now)
        #expect(r.recent.map(\.id) == [3])
        #expect(r.upcoming.isEmpty && r.active.isEmpty)
    }

    @Test func liveFutureMeetingIsUpcoming() {
        // untimed (no end) future meeting: state=active, focus in the future.
        let r = ActivityBuckets.partition(
            active: [manual(4)], stopped: [],
            events: [ev(1, 200, 4, .focus)], now: now)
        #expect(r.upcoming.map(\.id) == [4])
    }

    @Test func liveBackdropStaysActiveEvenWhenBlurred() {
        // A live backdrop the user toggled off (blur in the past) must NOT fall
        // into Recent — a blur on a live row means "unfocused", not "ended".
        let r = ActivityBuckets.partition(
            active: [manual(5)], stopped: [],
            events: [ev(1, 10, 5, .focus), ev(2, 50, 5, .blur)], now: now)
        #expect(r.active.map(\.id) == [5])
        #expect(r.recent.isEmpty)
    }

    @Test func autoActivityIsAlwaysActive() {
        let r = ActivityBuckets.partition(
            active: [auto(6)], stopped: [], events: [], now: now)
        #expect(r.active.map(\.id) == [6])
    }

    @Test func upcomingIsSortedByStart() {
        let r = ActivityBuckets.partition(
            active: [], stopped: [manual(7), manual(8)],
            events: [ev(1, 300, 7, .focus), ev(2, 150, 8, .focus)], now: now)
        #expect(r.upcoming.map(\.id) == [8, 7])   // 150 before 300
    }
}
