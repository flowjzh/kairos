import Testing
import Foundation
@testable import KairosStore
import KairosCore

/// M2 read-path hardening: range-bounded event loading must stay correct for
/// activities that straddle the `from` boundary, batch resolution must match
/// the per-activity result, and writes must signal the change stream.
@Suite
struct StoreHardeningTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    @Test
    func activityOpenedBeforeRangeStillAttributes() async throws {
        // Opened at 5, closed at 25, range [10, 30] → must yield [10, 25].
        let s = try store()
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "M", metadata: nil, ts: 5)
        try await s.closeActivity(activityId: act, ts: 25)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments == [Segment(activityId: act, start: 10, end: 25, seconds: 15, rule: "explicit")])
    }

    @Test
    func stillOpenActivityFromBeforeRangeAttributesToRangeEnd() async throws {
        // Opened at 5, never closed, range [10, 30] → [10, 30] (billed to end).
        let s = try store()
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "M", metadata: nil, ts: 5)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments == [Segment(activityId: act, start: 10, end: 30, seconds: 20, rule: "explicit")])
    }

    @Test
    func activityClosedBeforeRangeIsExcluded() async throws {
        // Opened at 5, closed at 8, range [10, 30] → nothing.
        let s = try store()
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "M", metadata: nil, ts: 5)
        try await s.closeActivity(activityId: act, ts: 8)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments.isEmpty)
    }

    @Test
    func afkSpanOpenBeforeRangeStillHolesAi() async throws {
        // afk_on at 5 (before range), ai window [0,100] via a submit at 100.
        // Range [50,60]: the still-open afk must hole the ai claim → nothing.
        let s = try store()
        let act = try await s.openActivity(source: "claude-code", externalId: "s1", project: "p", title: nil, metadata: nil, ts: 0)
        let src = try await s.resolveSource(slug: "idle")
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 5)
        let cc = try await s.resolveSource(slug: "claude-code")
        _ = try await s.appendEvent(activityId: act, sourceId: cc, kind: .aiSubmit, ts: 100)

        let result = try await s.attributedSegments(from: 50, to: 60)
        #expect(result.segments.isEmpty)   // afk (open from 5) covers the whole range
    }

    @Test
    func batchResolutionMatchesPrecedence() async throws {
        // override beats map; ensure batch path preserves override > map.
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        try await s.setMapping(project: "p", clientId: acme, billable: true)
        let act = try await s.openActivity(source: "manual", externalId: nil, project: "p", title: "T", metadata: nil, ts: 0)
        let src = try await s.resolveSource(slug: "manual")
        let payload = try JSONEncoder().encode(OverridePayload(clientId: vault, billable: false))
        _ = try await s.appendEvent(activityId: act, sourceId: src, kind: .activityOverride, ts: 0, payload: payload)
        try await s.closeActivity(activityId: act, ts: 100)

        let result = try await s.attributedSegments(from: 0, to: 1000)
        #expect(result.activities[act]?.client.clientId == vault)      // override wins
        #expect(result.activities[act]?.client.billable == false)
        #expect(result.activities[act]?.clientName == "Vault")
    }

    @Test
    func appendSignalsChangeStream() async throws {
        let s = try store()
        let stream = await s.changes()
        var iterator = stream.makeAsyncIterator()
        let src = try await s.resolveSource(slug: "idle")
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .pauseOn, ts: 0)
        let signal: Void? = await iterator.next()
        #expect(signal != nil)
    }
}
