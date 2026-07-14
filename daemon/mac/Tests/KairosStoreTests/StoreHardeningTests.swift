import Testing
import Foundation
@testable import KairosStore
import KairosCore

/// Read-path hardening: range-bounded loading must stay correct for focus
/// intervals that straddle the `from` boundary, batch resolution must preserve
/// override > map, and writes must signal the change stream.
@Suite
struct StoreHardeningTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    private func focusAt(_ s: Store, _ id: Int64, _ ts: Double) async throws {
        try await s.appendActivityEvent(activityId: id, kind: .focus, ts: ts)
    }
    private func blurAt(_ s: Store, _ id: Int64, _ ts: Double) async throws {
        try await s.appendActivityEvent(activityId: id, kind: .blur, ts: ts)
    }

    @Test
    func focusedBeforeRangeStillAttributes() async throws {
        // Focus at 5, blur at 25, range [10, 30] → [10, 25].
        let s = try store()
        let act = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "M", metadata: nil)
        try await focusAt(s, act, 5)
        try await blurAt(s, act, 25)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments == [Segment(activityId: act, start: 10, end: 25, seconds: 15, rule: "focus")])
    }

    @Test
    func stillFocusedFromBeforeRangeAttributesToRangeEnd() async throws {
        // Focus at 5, never blurred, range [10, 30] → [10, 30].
        let s = try store()
        let act = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "M", metadata: nil)
        try await focusAt(s, act, 5)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments == [Segment(activityId: act, start: 10, end: 30, seconds: 20, rule: "focus")])
    }

    @Test
    func blurredBeforeRangeIsExcluded() async throws {
        // Focus at 5, blur at 8, range [10, 30] → nothing.
        let s = try store()
        let act = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "M", metadata: nil)
        try await focusAt(s, act, 5)
        try await blurAt(s, act, 8)

        let result = try await s.attributedSegments(from: 10, to: 30)
        #expect(result.segments.isEmpty)
    }

    @Test
    func afkSpanOpenBeforeRangeStillHoles() async throws {
        // Focus at 0; afk_on at 5 (still open). Range [50,60]: the open afk holes
        // the whole range → nothing.
        let s = try store()
        let act = try await s.startActivity(source: "claude-code", externalId: "s1", project: "p", title: nil, metadata: nil)
        try await focusAt(s, act, 0)
        let idle = try await s.resolveSource(slug: "idle")
        _ = try await s.appendEvent(activityId: nil, sourceId: idle, kind: .afkOn, ts: 5)

        let result = try await s.attributedSegments(from: 50, to: 60)
        #expect(result.segments.isEmpty)
    }

    @Test
    func batchResolutionMatchesPrecedence() async throws {
        // override beats map; ensure the batch path preserves override > map.
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        try await s.setMapping(project: "p", clientId: acme, billable: true)
        let act = try await s.startActivity(source: "manual", externalId: nil, project: "p", title: "T", metadata: nil)
        let payload = try JSONEncoder().encode(OverridePayload(clientId: vault, billable: false))
        try await s.appendActivityEvent(activityId: act, kind: .activityOverride, ts: 0, payload: payload)
        try await focusAt(s, act, 0)
        try await blurAt(s, act, 100)

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
