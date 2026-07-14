import Testing
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

@Suite
struct SessionRegistryTests {
    @Test
    func resolveAfterRegister() async {
        let r = SessionRegistry()
        #expect(await r.resolve("k1") == nil)
        let flush = await r.register("k1", activityId: 7)
        #expect(flush == nil)
        #expect(await r.resolve("k1") == 7)
    }

    @Test
    func bufferedFocusReturnedOnceOnRegister() async {
        let r = SessionRegistry()
        await r.buffer("k1", focused: false, ts: 42)
        let flush = await r.register("k1", activityId: 7)
        #expect(flush == SessionRegistry.Pending(focused: false, ts: 42))
        #expect(await r.register("k1", activityId: 7) == nil)   // consumed
    }

    @Test
    func bufferLatestWins() async {
        let r = SessionRegistry()
        await r.buffer("k1", focused: true, ts: 1)
        await r.buffer("k1", focused: false, ts: 2)
        let flush = await r.register("k1", activityId: 9)
        #expect(flush == SessionRegistry.Pending(focused: false, ts: 2))
    }

    @Test
    func lastRegisterWins() async {
        let r = SessionRegistry()
        _ = await r.register("k1", activityId: 1)
        _ = await r.register("k1", activityId: 2)
        #expect(await r.resolve("k1") == 2)
    }

    @Test
    func afkImmuneSetIsTracked() async {
        let r = SessionRegistry()
        #expect(await r.isAfkImmune(5) == false)
        await r.setAfkImmune(5, true)
        #expect(await r.isAfkImmune(5) == true)
        await r.setAfkImmune(5, false)
        #expect(await r.isAfkImmune(5) == false)
    }
}

@Suite
struct FocusReportTests {
    private let now: @Sendable () -> Double = { 1_000_000 }
    private let d = Dispatcher()

    private func env(_ method: Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }

    private func start(_ store: Store, externalId: String = "s1", kid: String? = nil) async throws {
        _ = await d.handle(env(.activitiesStart, try Wire.encodeValue(
            ActivitiesStartParams(source: "claude-code", externalId: externalId, project: nil,
                                  title: nil, metadata: nil, kairosSessionId: kid))),
            store: store, now: now)
    }

    private func report(_ store: Store, kid: String, focused: Bool, ts: Double) async throws -> ResponseEnvelope {
        await d.handle(env(.focusReport, try Wire.encodeValue(
            FocusReportParams(kairosSessionId: kid, focused: focused, ts: ts))),
            store: store, now: now)
    }

    private func focusEvents(_ store: Store) async throws -> [Event] {
        try await store.loadEvents().filter { $0.kind == .focus || $0.kind == .blur }
    }

    @Test
    func mappedBlurAppendsBlurOnActivity() async throws {
        let store = try Store(path: ":memory:")
        try await start(store, externalId: "s1", kid: "k1")
        _ = try await report(store, kid: "k1", focused: false, ts: now() + 5)
        let ev = try await focusEvents(store)
        #expect(ev.map(\.kind) == [.blur])
        #expect(ev[0].ts == now() + 5)
        #expect(ev[0].activityId == (try await store.findActivity(source: "claude-code", externalId: "s1")))
    }

    @Test
    func mappedFocusAppendsFocus() async throws {
        let store = try Store(path: ":memory:")
        try await start(store, kid: "k1")
        _ = try await report(store, kid: "k1", focused: true, ts: now() + 1)
        #expect(try await focusEvents(store).map(\.kind) == [.focus])
    }

    @Test
    func focusBeforeMappingBuffersThenFlushesOnHook() async throws {
        let store = try Store(path: ":memory:")
        _ = try await report(store, kid: "k1", focused: false, ts: now() + 2)
        #expect(try await focusEvents(store).isEmpty)          // buffered, not yet appended
        try await start(store, externalId: "s1", kid: "k1")    // SessionStart registers -> flush
        let ev = try await focusEvents(store)
        #expect(ev.map(\.kind) == [.blur])
        #expect(ev[0].ts == now() + 2)
    }

    @Test
    func anyHookRegistersMappingNotJustSessionStart() async throws {
        let store = try Store(path: ":memory:")
        try await start(store, externalId: "s1", kid: nil)     // started, but mapping unknown
        _ = await d.handle(env(.eventsPost, try Wire.encodeValue(
            EventsPostParams(activity: ActivityRef(source: "claude-code", externalId: "s1"),
                             kind: "ai_submit", ts: now(), payload: nil, kairosSessionId: "k1"))),
            store: store, now: now)                             // a Submit hook carries the kid
        _ = try await report(store, kid: "k1", focused: false, ts: now() + 1)
        #expect(try await focusEvents(store).map(\.kind) == [.blur])
    }

    @Test
    func unmappedFocusIsDroppedNotErrored() async throws {
        let store = try Store(path: ":memory:")
        let resp = try await report(store, kid: "ghost", focused: true, ts: now())
        if case .error(let e) = resp { Issue.record("unexpected error: \(e)"); return }
        #expect(try await focusEvents(store).isEmpty)
    }

    @Test
    func rejectsFutureTs() async throws {
        let store = try Store(path: ":memory:")
        try await start(store, kid: "k1")
        let resp = try await report(store, kid: "k1", focused: true, ts: now() + 10_000)
        guard case .error(let e) = resp else { Issue.record("expected error"); return }
        #expect(e.code == "bad_request")
    }
}
