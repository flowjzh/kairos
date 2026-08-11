import Testing
@testable import KairosServer
import KairosCore
import KairosStore

/// The `StatusIndex` cache invariants the fixed-`now` DispatcherTests can't
/// cover: the live focus tail between events, watermark-driven rebuilds, a zero
/// rate while afk, and grace expiry resolved live from `now`.
@Suite
struct StatusIndexTests {
    private func makeActivity(_ store: Store, externalId: String = "s1") async throws -> Int64 {
        try await store.startActivity(source: "claude-code", externalId: externalId, project: nil, title: nil, metadata: nil)
    }

    @Test
    func liveTailGrowsBetweenEvents_withoutRebuild() async throws {
        let store = try Store(path: ":memory:")
        let id = try await makeActivity(store)
        try await store.appendEvent(activityId: id, kind: .focus, ts: 1000)

        let idx = StatusIndex()
        let first = await idx.query(store: store, id: id, now: 1100)   // build @ 1100
        #expect(first.total == 100)          // focus [1000, 1100]
        #expect(first.state == .focused)

        // Same watermark → cache hit; the focused activity's tail extends to now.
        let second = await idx.query(store: store, id: id, now: 1150)
        #expect(second.total == 150)         // 100 settled + 50 tail
        #expect(second.state == .focused)
    }

    @Test
    func watermarkBumpRebuildsAndDropsTail() async throws {
        // Manual activity: a blur is an intentional stop (no grace), so the
        // state after blur is deterministically idle, independent of grace.
        let store = try Store(path: ":memory:")
        let id = try await store.startActivity(source: "manual", externalId: "m1", project: nil, title: nil, metadata: nil)
        try await store.appendEvent(activityId: id, kind: .focus, ts: 1000)
        let idx = StatusIndex()
        _ = await idx.query(store: store, id: id, now: 1100)            // settled 100

        try await store.appendEvent(activityId: id, kind: .blur, ts: 1200) // watermark bumps
        let after = await idx.query(store: store, id: id, now: 1300)    // rebuild @ 1300
        // focus [1000,1200] = 200; blur @1200 → idle (manual, no grace), no tail.
        #expect(after.total == 200)
        #expect(after.state == .idle)
    }

    @Test
    func afkZeroRate_doesNotGrowTail() async throws {
        let store = try Store(path: ":memory:")
        let id = try await makeActivity(store)
        try await store.appendEvent(activityId: id, kind: .focus, ts: 1000)
        try await store.appendEvent(activityId: nil, kind: .afkOn, ts: 1050) // global afk
        let idx = StatusIndex()

        let at = await idx.query(store: store, id: id, now: 1100)
        #expect(at.total == 50)             // [1000,1100] minus afk [1050,1100]
        #expect(at.state == .focused)       // afk never clears the focus pointer

        // Still afk, no new event → tail rate is 0; total must not advance.
        let later = await idx.query(store: store, id: id, now: 1200)
        #expect(later.total == 50)
    }

    @Test
    func gracingExpiresLiveFromNow_withoutRebuild() async throws {
        AppSettings.register()
        let grace = AppSettings.grace
        guard grace > 0 else { Issue.record("default grace must be > 0"); return }

        let store = try Store(path: ":memory:")
        let id = try await makeActivity(store)
        try await store.appendEvent(activityId: id, kind: .focus, ts: 1000)
        try await store.appendEvent(activityId: id, kind: .blur, ts: 1050)
        let idx = StatusIndex()

        let within = await idx.query(store: store, id: id, now: 1051)   // 1 s into grace
        #expect(within.state == .gracing)

        // Same watermark; only `now` advanced past expiry. derive(now) flips it
        // to idle with no rebuild and no timer.
        let expired = await idx.query(store: store, id: id, now: 1050 + grace + 1)
        #expect(expired.state == .idle)
    }
}
