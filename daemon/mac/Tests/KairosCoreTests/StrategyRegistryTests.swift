import Testing
@testable import KairosCore

@Suite
struct StrategyRegistryTests {
    private func ev(_ id: Int64, _ ts: Double, _ activityId: Int64?, _ kind: EventKind) -> Event {
        Event(id: id, ts: ts, activityId: activityId, kind: kind)
    }

    @Test
    func currentVersionResolvesToCompute() {
        let events = [ev(1, 0, 1, .activityOpen), ev(2, 100, 1, .activityClose)]
        let computer = StrategyRegistry.computer(version: StrategyRegistry.currentVersion)
        #expect(computer != nil)
        #expect(computer?(events, 0, 200) == Attribution.compute(events: events, from: 0, to: 200))
    }

    @Test
    func unknownVersionIsNil() {
        #expect(StrategyRegistry.computer(version: "does-not-exist") == nil)
    }
}
