import Testing
import Foundation
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

/// End-to-end: drive a realistic `kairos claude` session (hooks + wrapper focus)
/// through the dispatcher → store → attribution, then read segments back. The
/// hook→RPC mapping itself lives in the Rust plugin (tested there); here we build
/// the same requests inline. Since M4p3 timing is the wrapper's focus/blur, with
/// ai_submit/ai_stop as grind deductions.
@Suite
struct ClaudeSessionE2ETests {
    private let d = Dispatcher()
    private let kid = "k1"

    private func hook(_ event: String, session: String, project: String, ts: Double, store: Store) async throws {
        let request: RequestEnvelope
        let activity = ActivityRef(source: "claude-code", externalId: session)
        switch event {
        case "SessionStart":
            let metadata: [String: JSONValue] = [
                "transcript_path": .string("/t/\(session).jsonl"),
                "cwd": .string("/work/\(project)"),
            ]
            request = try RequestEnvelope(method: .activitiesStart, params: Wire.encodeValue(
                ActivitiesStartParams(source: "claude-code", externalId: session, project: project, title: nil, metadata: metadata, kairosSessionId: kid)))
        case "UserPromptSubmit":
            request = try RequestEnvelope(method: .eventsPost, params: Wire.encodeValue(
                EventsPostParams(activity: activity, kind: "ai_submit", ts: ts, payload: nil, kairosSessionId: kid)))
        case "Stop":
            request = try RequestEnvelope(method: .eventsPost, params: Wire.encodeValue(
                EventsPostParams(activity: activity, kind: "ai_stop", ts: ts, payload: nil, kairosSessionId: kid)))
        case "SessionEnd":
            request = try RequestEnvelope(method: .activitiesStop, params: Wire.encodeValue(
                ActivitiesStopParams(source: "claude-code", externalId: session, kairosSessionId: kid, ts: ts)))
        default:
            Issue.record("unexpected hook event: \(event)")
            return
        }
        let resp = await d.handle(request, store: store, now: { ts })
        if case .error(let e) = resp { Issue.record("hook \(event) errored: \(e)") }
    }

    /// The wrapper's focus report, keyed by kid.
    private func focus(_ focused: Bool, ts: Double, store: Store) async throws {
        _ = await d.handle(env(.focusReport, try Wire.encodeValue(
            FocusReportParams(kairosSessionId: kid, focused: focused, ts: ts))), store: store, now: { ts })
    }

    private func injectAfk(_ store: Store, on: Double, off: Double) async throws {
        _ = try await store.appendEvent(activityId: nil, kind: .afkOn, ts: on)
        _ = try await store.appendEvent(activityId: nil, kind: .afkOff, ts: off)
    }

    @Test
    func focusedSessionHumanTimeExcludesGrindAndAfk() async throws {
        let store = try Store(path: ":memory:")
        let acme = await d.handle(env(.clientsAdd, try Wire.encodeValue(ClientsAddParams(name: "Acme"))), store: store, now: { 0 })
        guard case .result(let v) = acme else { Issue.record("client add"); return }
        let acmeId = try Wire.decodeValue(v, as: ClientsAddResult.self).id
        _ = await d.handle(env(.mappingSet, try Wire.encodeValue(MappingSetParams(project: "proj", clientId: acmeId, billable: true))), store: store, now: { 0 })

        try await hook("SessionStart",     session: "s1", project: "proj", ts: 1000, store: store)  // register kid
        try await focus(true, ts: 1000, store: store)                                                // launch focus
        try await hook("UserPromptSubmit", session: "s1", project: "proj", ts: 1010, store: store)  // grind [1010,
        try await hook("Stop",             session: "s1", project: "proj", ts: 1020, store: store)  //        1020]
        try await injectAfk(store, on: 1030, off: 1090)                                              // lunch (holed)
        try await hook("UserPromptSubmit", session: "s1", project: "proj", ts: 1100, store: store)  // grind [1100,
        try await hook("Stop",             session: "s1", project: "proj", ts: 1110, store: store)  //        1110]
        try await hook("SessionEnd",       session: "s1", project: "proj", ts: 1200, store: store)  // blur + stopped

        let result = try await store.attributedSegments(from: 0, to: 2000)
        let segs = result.segments.sorted { $0.start < $1.start }
        // focus [1000,1200]=200 − grinds(20) − afk(60) = 120, over 4 pieces.
        #expect(segs.map { [$0.start, $0.end] } == [[1000, 1010], [1020, 1030], [1090, 1100], [1110, 1200]])
        #expect(segs.reduce(0) { $0 + $1.seconds } == 120)
        let activityId = segs[0].activityId
        #expect(result.activities[activityId]?.client.clientId == acmeId)   // resolved via the project tag
        #expect(result.activities[activityId]?.record.project == "proj")
    }

    private func env(_ method: KairosRPC.Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }
}
