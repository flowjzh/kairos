import Testing
import Foundation
@testable import KairosServer
import KairosClaudeCode
import KairosCore
import KairosRPC
import KairosStore

/// End-to-end M2: drive a realistic Claude Code session through the *actual*
/// plugin mapping (`ClaudeCodeHook`) → the dispatcher → the store, then read
/// segments back — the full ingest-to-attribution path minus the socket wire.
@Suite
struct ClaudeSessionE2ETests {
    private let d = Dispatcher()

    /// Dispatch a hook event at time `ts` exactly as the plugin binary would:
    /// build the request via the mapping, then hand it to the dispatcher with
    /// `now` pinned to that instant (so server-stamped opens land correctly).
    private func hook(_ event: String, session: String, project: String, ts: Double, store: Store) async throws {
        let cwd = "/work/\(project)"
        let input = HookInput(sessionId: session, cwd: cwd, transcriptPath: "/t/\(session).jsonl", hookEventName: event)
        let request = try #require(ClaudeCodeHook.request(from: input, now: ts))
        let now: @Sendable () -> Double = { ts }
        let resp = await d.handle(request, store: store, now: now)
        if case .error(let e) = resp { Issue.record("hook \(event) errored: \(e)") }
    }

    private func injectAfk(_ store: Store, on: Double, off: Double) async throws {
        let src = try await store.resolveSource(slug: DaemonSources.idle)
        _ = try await store.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: on)
        _ = try await store.appendEvent(activityId: nil, sourceId: src, kind: .afkOff, ts: off)
    }

    @Test
    func singleSessionHumanTimeExcludesAiExecution() async throws {
        let store = try Store(path: ":memory:")
        // A tagged project so the segment resolves to a billing client.
        let acme = await d.handle(env(.clientsAdd, try Wire.encodeValue(ClientsAddParams(name: "Acme"))), store: store, now: { 0 })
        guard case .result(let v) = acme else { Issue.record("client add"); return }
        let acmeId = try Wire.decodeValue(v, as: ClientsAddResult.self).id
        _ = await d.handle(env(.mappingSet, try Wire.encodeValue(MappingSetParams(project: "proj", clientId: acmeId, billable: true))), store: store, now: { 0 })

        // A session: open, turn 1, break (afk), turn 2, trailing stop (open tail), end.
        try await hook("SessionStart",     session: "s1", project: "proj", ts: 1000, store: store)  // open @1000
        try await hook("UserPromptSubmit", session: "s1", project: "proj", ts: 1010, store: store)  // window [1000,1010]
        try await hook("Stop",             session: "s1", project: "proj", ts: 1020, store: store)  // agent grinds [1010,1020]
        try await injectAfk(store, on: 1030, off: 1090)                                              // lunch
        try await hook("UserPromptSubmit", session: "s1", project: "proj", ts: 1100, store: store)  // window [1020,1100] − afk
        try await hook("Stop",             session: "s1", project: "proj", ts: 1110, store: store)  // open tail (not counted)
        try await hook("SessionEnd",       session: "s1", project: "proj", ts: 1200, store: store)  // close

        let result = try await store.attributedSegments(from: 0, to: 2000)
        let ai = result.segments.filter { $0.rule == "ai" }.sorted { $0.start < $1.start }
        #expect(ai == [
            Segment(activityId: ai[0].activityId, start: 1000, end: 1010, seconds: 10, rule: "ai"),
            Segment(activityId: ai[1].activityId, start: 1020, end: 1030, seconds: 10, rule: "ai"),
            Segment(activityId: ai[2].activityId, start: 1090, end: 1100, seconds: 10, rule: "ai"),
        ])
        // 30s human time; AI-execution ([1010,1020],[1100,1110]) excluded; afk holed the break.
        #expect(ai.reduce(0) { $0 + $1.seconds } == 30)
        let activityId = ai[0].activityId
        #expect(result.activities[activityId]?.client.clientId == acmeId)   // resolved via the project tag
        #expect(result.activities[activityId]?.record.project == "proj")
    }

    private func env(_ method: KairosRPC.Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }
}
