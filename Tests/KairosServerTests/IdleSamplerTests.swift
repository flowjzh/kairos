import Testing
@testable import KairosServer

@Suite
struct IdleSamplerTests {
    @Test
    func idleCrossesUp() {
        let (state, events) = IdleSampler.sample(state: .init(), idleSeconds: 70, now: 100, threshold: 60)
        #expect(state.wasAfk == true)
        #expect(events == [.afkOn(reason: .idle, ts: 100)])
    }

    @Test
    func idleDropsBack() {
        let (state, events) = IdleSampler.sample(state: .init(wasAfk: true), idleSeconds: 5, now: 100, threshold: 60)
        #expect(state.wasAfk == false)
        #expect(events == [.afkOff(ts: 100)])
    }

    @Test
    func noTransitionWhenSteady() {
        let (_, e1) = IdleSampler.sample(state: .init(), idleSeconds: 5, now: 1, threshold: 60)
        #expect(e1.isEmpty)
        let (_, e2) = IdleSampler.sample(state: .init(wasAfk: true), idleSeconds: 80, now: 1, threshold: 60)
        #expect(e2.isEmpty)
    }

    @Test
    func sleepEvent() {
        let (state, events) = IdleSampler.sleep(state: .init(), ts: 200)
        #expect(state.wasAfk == true)
        #expect(events == [.afkOn(reason: .sleep, ts: 200)])
    }

    @Test
    func nestedSleepIgnored() {
        let (state, events) = IdleSampler.sleep(state: .init(wasAfk: true), ts: 200)
        #expect(state.wasAfk == true)
        #expect(events.isEmpty)
    }

    @Test
    func wakeEvent() {
        let (state, events) = IdleSampler.wake(state: .init(wasAfk: true), ts: 300)
        #expect(state.wasAfk == false)
        #expect(events == [.afkOff(ts: 300)])
    }

    @Test
    func startupGapEmitsOfflinePair() {
        let events = IdleSampler.startupGap(lastEventTs: 100, now: 500, pollInterval: 5)
        #expect(events == [.afkOn(reason: .offline, ts: 100), .afkOff(ts: 500)])
    }

    @Test
    func startupGapNoneWhenNoGap() {
        #expect(IdleSampler.startupGap(lastEventTs: 100, now: 103, pollInterval: 5).isEmpty)
        #expect(IdleSampler.startupGap(lastEventTs: nil, now: 500, pollInterval: 5).isEmpty)
    }
}
