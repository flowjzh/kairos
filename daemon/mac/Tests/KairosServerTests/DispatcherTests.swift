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
}
