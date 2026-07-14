import Testing
@testable import KairosServer

@Suite
struct IdleSamplerTests {
    @Test
    func idleCrossesUp() {
        let (state, events) = IdleSampler.sample(state: .init(), idleSeconds: 70, now: 100, threshold: 60, pollInterval: 5)
        #expect(state.afk == .idle)
        #expect(events == [.afkOn(reason: .idle, ts: 100)])
    }

    @Test
    func idleDropsBack() {
        let (state, events) = IdleSampler.sample(state: .init(afk: .idle), idleSeconds: 5, now: 100, threshold: 60, pollInterval: 5)
        #expect(state.afk == .none)
        #expect(events == [.afkOff(ts: 100)])
    }

    @Test
    func noTransitionWhenSteady() {
        let (_, e1) = IdleSampler.sample(state: .init(), idleSeconds: 5, now: 1, threshold: 60, pollInterval: 5)
        #expect(e1.isEmpty)
        let (_, e2) = IdleSampler.sample(state: .init(afk: .idle), idleSeconds: 80, now: 1, threshold: 60, pollInterval: 5)
        #expect(e2.isEmpty)
    }

    @Test
    func sleepEvent() {
        let (state, events) = IdleSampler.sleep(state: .init(), ts: 200)
        #expect(state.afk == .sleep)
        #expect(events == [.afkOn(reason: .sleep, ts: 200)])
    }

    @Test
    func nestedSleepIgnored() {
        let (state, events) = IdleSampler.sleep(state: .init(afk: .idle), ts: 200)
        #expect(state.afk == .idle)
        #expect(events.isEmpty)
    }

    @Test
    func wakeClosesSleepSpan() {
        let (state, events) = IdleSampler.wake(state: .init(afk: .sleep), ts: 300)
        #expect(state.afk == .none)
        #expect(events == [.afkOff(ts: 300)])
    }

    @Test
    func wakeClosesIdleSpanToo() {
        let (state, events) = IdleSampler.wake(state: .init(afk: .idle), ts: 300)
        #expect(state.afk == .none)
        #expect(events == [.afkOff(ts: 300)])
    }

    /// Regression: a `willSleep` span must NOT be cancelled by the very next
    /// idle poll, which sees near-zero idle because the lid was just closed.
    @Test
    func sleepSpanSurvivesFreshLowIdlePoll() {
        let (s1, _) = IdleSampler.sleep(state: .init(), ts: 100)
        let (s2, events) = IdleSampler.sample(state: s1, idleSeconds: 1, now: 105, threshold: 60, pollInterval: 5)
        #expect(events.isEmpty)
        #expect(s2.afk == .sleep)
    }

    /// Aborted sleep (machine never actually slept): the span stays open while
    /// the machine goes quiet (polls 5s apart), then closes when input resumes.
    @Test
    func abortedSleepClosesWhenInputResumes() {
        let (s1, _) = IdleSampler.sleep(state: .init(), ts: 100)
        let (s2, e2) = IdleSampler.sample(state: s1, idleSeconds: 65, now: 165, threshold: 60, pollInterval: 5)
        #expect(e2.isEmpty)
        #expect(s2.sleepIdled == true)
        let (s3, e3) = IdleSampler.sample(state: s2, idleSeconds: 2, now: 170, threshold: 60, pollInterval: 5)
        #expect(e3 == [.afkOff(ts: 170)])
        #expect(s3.afk == .none)
    }

    /// The reported bug: a system sleep that delivered no `willSleep` froze the
    /// poll timer. On resume the poll sees a huge time jump and backfills the
    /// gap as afk, then closes it because input has resumed.
    @Test
    func pollGapBackfillsUndeliveredSleep() {
        let before = IdleSampler.State(afk: .none, lastPoll: 100)
        let (s1, e1) = IdleSampler.sample(state: before, idleSeconds: 2, now: 800, threshold: 60, pollInterval: 5)
        #expect(e1 == [.afkOn(reason: .offline, ts: 100), .afkOff(ts: 800)])
        #expect(s1.afk == .none)
    }

    /// Gap on resume but still idle (no input yet) → the backfilled span stays
    /// open and closes on a later active poll.
    @Test
    func pollGapStaysOpenWhenStillIdle() {
        let before = IdleSampler.State(afk: .none, lastPoll: 100)
        let (s1, e1) = IdleSampler.sample(state: before, idleSeconds: 900, now: 800, threshold: 60, pollInterval: 5)
        #expect(e1 == [.afkOn(reason: .offline, ts: 100)])
        #expect(s1.afk == .idle)
    }

    /// Ordinary timer jitter (a few seconds over the interval) is not a gap.
    @Test
    func smallPollJitterIsNotAGap() {
        let before = IdleSampler.State(afk: .none, lastPoll: 100)
        let (s1, e1) = IdleSampler.sample(state: before, idleSeconds: 2, now: 108, threshold: 60, pollInterval: 5)
        #expect(e1.isEmpty)
        #expect(s1.afk == .none)
    }

    /// An already-open idle span across a gap isn't double-counted: no backfill,
    /// the open span just continues.
    @Test
    func pollGapDoesNotDoubleCountOpenSpan() {
        let before = IdleSampler.State(afk: .idle, lastPoll: 100)
        let (s1, e1) = IdleSampler.sample(state: before, idleSeconds: 900, now: 800, threshold: 60, pollInterval: 5)
        #expect(e1.isEmpty)
        #expect(s1.afk == .idle)
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
