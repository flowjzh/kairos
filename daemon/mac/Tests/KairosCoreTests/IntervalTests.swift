import Testing
@testable import KairosCore

@Suite
struct IntervalTests {
    @Test
    func containsChecksFullContainment() {
        let meeting = Interval(start: 120, end: 180)
        #expect(meeting.contains(Interval(start: 130, end: 140)))
        #expect(!meeting.contains(Interval(start: 110, end: 130)))
        #expect(!meeting.contains(Interval(start: 130, end: 200)))
        #expect(meeting.contains(Interval(start: 120, end: 180)))
    }

    @Test
    func subtractNoHoles() {
        #expect(Interval.subtract(Interval(start: 0, end: 3600), []) == [Interval(start: 0, end: 3600)])
    }

    @Test
    func subtractMiddleHoleSplits() {
        let pieces = Interval.subtract(Interval(start: 0, end: 3600), [Interval(start: 1800, end: 2400)])
        #expect(pieces == [Interval(start: 0, end: 1800), Interval(start: 2400, end: 3600)])
    }

    @Test
    func subtractFullHoleEmpties() {
        #expect(Interval.subtract(Interval(start: 0, end: 3600), [Interval(start: 0, end: 3600)]) == [])
    }

    @Test
    func subtractMultipleHoles() {
        let pieces = Interval.subtract(Interval(start: 0, end: 3600), [
            Interval(start: 500, end: 1000),
            Interval(start: 2000, end: 2500),
        ])
        #expect(pieces == [
            Interval(start: 0, end: 500),
            Interval(start: 1000, end: 2000),
            Interval(start: 2500, end: 3600),
        ])
    }

    @Test
    func subtractOverlappingHolesMerge() {
        let pieces = Interval.subtract(Interval(start: 0, end: 3600), [
            Interval(start: 1000, end: 2000),
            Interval(start: 1500, end: 2500),
        ])
        #expect(pieces == [Interval(start: 0, end: 1000), Interval(start: 2500, end: 3600)])
    }
}
