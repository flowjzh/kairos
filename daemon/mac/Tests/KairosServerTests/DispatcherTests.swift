import Testing
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

@Suite
struct DispatcherTests {
    private let now: @Sendable () -> Double = { 1_000_000 }
    private let d = Dispatcher()

    private func env(_ method: Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }

    private func startActivity(_ store: Store, source: String = "claude-code", externalId: String = "s1", project: String? = nil) async throws {
        _ = await d.handle(
            env(.activitiesStart, try Wire.encodeValue(ActivitiesStartParams(source: source, externalId: externalId, project: project, title: nil, metadata: nil))),
            store: store, now: now
        )
    }

    @Test
    func startWritesNoEvent_thenEventsPostAppends() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        #expect(try await store.eventsWatermark() == 0)   // start is identity/lifecycle only
        let resp = await d.handle(
            env(.eventsPost, try Wire.encodeValue(EventsPostParams(
                activity: ActivityRef(source: "claude-code", externalId: "s1"),
                kind: "ai_submit", ts: now(), payload: nil))),
            store: store, now: now
        )
        guard case .result(let v) = resp else { Issue.record("expected result"); return }
        #expect(v == .object([:]))   // empty result {}
        #expect(try await store.eventsWatermark() == 1)   // just ai_submit
    }

    @Test
    func eventsPostRejectsFutureTs() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        let resp = await d.handle(
            env(.eventsPost, try Wire.encodeValue(EventsPostParams(
                activity: ActivityRef(source: "claude-code", externalId: "s1"),
                kind: "ai_stop", ts: now() + 10_000, payload: nil))),
            store: store, now: now
        )
        guard case .error(let e) = resp else { Issue.record("expected error"); return }
        #expect(e.code == "bad_request")
    }

    @Test
    func eventsPostRejectsUnknownKind() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        let resp = await d.handle(
            env(.eventsPost, try Wire.encodeValue(EventsPostParams(
                activity: ActivityRef(source: "claude-code", externalId: "s1"),
                kind: "bogus", ts: now(), payload: nil))),
            store: store, now: now
        )
        guard case .error(let e) = resp else { Issue.record("expected error"); return }
        #expect(e.code == "bad_request")
    }

    @Test
    func controlPauseAppendsPauseEvent() async throws {
        let store = try Store(path: ":memory:")
        let resp = await d.handle(
            env(.controlPause, try Wire.encodeValue(ControlPauseParams(paused: true, ts: now()))),
            store: store, now: now
        )
        if case .error(let e) = resp { Issue.record("unexpected error: \(e)"); return }
        #expect(try await store.eventsWatermark() == 1)
    }

    @Test
    func focusSetThenStopProducesSegment() async throws {
        let store = try Store(path: ":memory:")
        let addResp = await d.handle(env(.clientsAdd, try Wire.encodeValue(ClientsAddParams(name: "Acme"))), store: store, now: now)
        guard case .result(let v) = addResp else { Issue.record(); return }
        let acme = try Wire.decodeValue(v, as: ClientsAddResult.self).id
        _ = await d.handle(env(.mappingSet, try Wire.encodeValue(MappingSetParams(project: "p1", clientId: acme, billable: true))), store: store, now: now)
        try await startActivity(store, externalId: "s1", project: "p1")
        // focus at now, stop (blur) at now+30 → a 30s focus segment.
        _ = await d.handle(env(.focusSet, try Wire.encodeValue(FocusSetParams(source: "claude-code", externalId: "s1", ts: now()))), store: store, now: now)
        _ = await d.handle(env(.activitiesStop, try Wire.encodeValue(ActivitiesStopParams(source: "claude-code", externalId: "s1", ts: now() + 30))), store: store, now: { self.now() + 30 })

        let resp = await d.handle(
            env(.segmentsGet, try Wire.encodeValue(SegmentsGetParams(from: 0, to: now() + 100, project: nil, client: nil))),
            store: store, now: now
        )
        guard case .result(let v) = resp else { Issue.record(); return }
        let result = try Wire.decodeValue(v, as: SegmentsGetResult.self)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].seconds == 30)
        #expect(result.activities.first?.value.client?.id == acme)
        #expect(result.activities.first?.value.project == "p1")
    }

    @Test
    func clientsAddRenameList() async throws {
        let store = try Store(path: ":memory:")
        let addResp = await d.handle(env(.clientsAdd, try Wire.encodeValue(ClientsAddParams(name: "Acme"))), store: store, now: now)
        guard case .result(let v) = addResp else { Issue.record(); return }
        let id = try Wire.decodeValue(v, as: ClientsAddResult.self).id
        _ = await d.handle(env(.clientsRename, try Wire.encodeValue(ClientsRenameParams(id: id, name: "Acme Corp"))), store: store, now: now)
        let listResp = await d.handle(env(.clientsList, .null), store: store, now: now)
        guard case .result(let v) = listResp else { Issue.record(); return }
        let list = try Wire.decodeValue(v, as: ClientsListResult.self)
        #expect(list.clients == [ClientEntry(id: id, name: "Acme Corp")])
    }

    // MARK: activities.status

    /// Request the statusline payload for one activity.
    private func status(_ store: Store, source: String = "claude-code", externalId: String = "s1") async throws -> ActivityStatusResult {
        let resp = await d.handle(
            env(.activitiesStatus, try Wire.encodeValue(ActivitiesStatusParams(source: source, externalId: externalId))),
            store: store, now: now
        )
        guard case .result(let v) = resp else { Issue.record("expected result, got error"); return ActivityStatusResult() }
        return try Wire.decodeValue(v, as: ActivityStatusResult.self)
    }

    /// `AppSettings.grace` reads UserDefaults, which returns 0 (grace "off") for
    /// an unset key unless defaults are registered. Register them so the gracing
    /// test's blur-within-grace actually qualifies as pending.
    private func registerDefaults() {
        AppSettings.register()
    }

    @Test
    func statusNotFoundReturnsErrorFieldNotRpcError() async throws {
        let store = try Store(path: ":memory:")
        // No activity started → the handler returns a result with an `error` key,
        // NOT an RPC error envelope.
        let r = try await status(store, externalId: "missing")
        #expect(r.error != nil)
        #expect(r.error?.color == "red")
        #expect(r.state == nil)   // normal fields absent in the error shape
    }

    @Test
    func statusFocusedIsGreen() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        let id = try await store.findActivity(source: "claude-code", externalId: "s1")!
        _ = try await store.appendEvent(activityId: id, kind: .focus, ts: now() - 30)
        let r = try await status(store)
        #expect(r.state?.color == "green")
        #expect(r.error == nil)
    }

    @Test
    func statusGracingIsLightGreen() async throws {
        registerDefaults()
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        let id = try await store.findActivity(source: "claude-code", externalId: "s1")!
        // Focus then blur-to-void within grace (no re-focus) → the blur stands,
        // nobody is focused, and Grace.pending reports it → light-green.
        _ = try await store.appendEvent(activityId: id, kind: .focus, ts: now() - 60)
        _ = try await store.appendEvent(activityId: id, kind: .blur, ts: now() - 10)
        let r = try await status(store)
        #expect(r.state?.color == "light-green")
    }

    @Test
    func statusIdleIsGray() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        // Never focused → neither focused nor gracing → gray.
        let r = try await status(store)
        #expect(r.state?.color == "gray")
    }

    @Test
    func statusTodayAndTotalFormatted() async throws {
        let store = try Store(path: ":memory:")
        try await startActivity(store)
        let id = try await store.findActivity(source: "claude-code", externalId: "s1")!
        _ = try await store.appendEvent(activityId: id, kind: .focus, ts: now() - 90)
        let r = try await status(store)
        // 90 s of focus → "1m" (90/60 = 1 after rounding).
        #expect(r.total?.text == "1m")
        #expect(r.today?.text == "1m")
        #expect(r.activity?.text == nil)   // startActivity passes no project/title → no name
    }

    @Test
    func statusDurationFormatsHoursAndDays() async throws {
        // Covers the hour and day-crossing formats via total. 5023 s → 1h23m;
        // 180178 s → 2d2h2m; 40 s rounds to 0m. A fresh dispatcher per case
        // mirrors production (one store per StatusIndex) so each isolated
        // :memory: store gets its own cache.
        for (span, expected) in [(5023.0, "1h23m"), (180178.0, "2d2h2m"), (40.0, "0m")] {
            let store = try Store(path: ":memory:")
            let d = Dispatcher()
            _ = await d.handle(env(.activitiesStart, try Wire.encodeValue(ActivitiesStartParams(source: "claude-code", externalId: "fmt", project: nil, title: nil, metadata: nil))), store: store, now: now)
            let id = try await store.findActivity(source: "claude-code", externalId: "fmt")!
            _ = try await store.appendEvent(activityId: id, kind: .focus, ts: now() - span)
            let resp = await d.handle(env(.activitiesStatus, try Wire.encodeValue(ActivitiesStatusParams(source: "claude-code", externalId: "fmt"))), store: store, now: now)
            guard case .result(let v) = resp else { Issue.record("expected result"); continue }
            let r = try Wire.decodeValue(v, as: ActivityStatusResult.self)
            #expect(r.total?.text == expected, "span \(span)s")
        }
    }
}
