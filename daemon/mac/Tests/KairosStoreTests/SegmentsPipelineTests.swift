import Testing
@testable import KairosStore
import KairosCore

@Suite
struct SegmentsPipelineTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    /// Focus an activity for `[start, end]` (the M4p3 timing base).
    private func focus(_ s: Store, _ id: Int64, _ start: Double, _ end: Double) async throws {
        try await s.appendActivityEvent(activityId: id, kind: .focus, ts: start)
        try await s.appendActivityEvent(activityId: id, kind: .blur, ts: end)
    }

    @Test
    func focusSegmentResolvesClient() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: true)
        let act = try await s.startActivity(source: "claude-code", externalId: "s1", project: "daemonclaw", title: "Build", metadata: nil)
        try await focus(s, act, 0, 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.count == 1)
        #expect(result.segments[0] == Segment(activityId: act, start: 0, end: 3600, seconds: 3600, rule: "focus"))
        #expect(result.activities[act]?.client.clientId == acme)
        #expect(result.activities[act]?.client.billable == true)
        #expect(result.activities[act]?.clientName == "Acme")
        #expect(result.activities[act]?.record.project == "daemonclaw")
        #expect(result.activities[act]?.record.source == "claude-code")
    }

    @Test
    func afkHolesFocusSegment() async throws {
        // With M4p3, afk holes the focused interval (AFK-immunity is a write-time
        // sampler gate, not a read-time rule — so afk in the log always deducts).
        let s = try store()
        let act = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        try await s.appendActivityEvent(activityId: act, kind: .focus, ts: 0)
        _ = try await s.appendEvent(activityId: nil, kind: .afkOn, ts: 1200)
        _ = try await s.appendEvent(activityId: nil, kind: .afkOff, ts: 2400)
        try await s.appendActivityEvent(activityId: act, kind: .blur, ts: 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.reduce(0) { $0 + $1.seconds } == 2400)   // 3600 − 1200 afk
    }

    @Test
    func pauseHolesFocusSegment() async throws {
        let s = try store()
        let act = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        try await s.appendActivityEvent(activityId: act, kind: .focus, ts: 0)
        _ = try await s.appendEvent(activityId: nil, kind: .pauseOn, ts: 1800)
        _ = try await s.appendEvent(activityId: nil, kind: .pauseOff, ts: 2400)
        try await s.appendActivityEvent(activityId: act, kind: .blur, ts: 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.count == 2)
        #expect(result.segments.reduce(0) { $0 + $1.seconds } == 3000)   // 3600 − 600 pause
    }

    @Test
    func filterByClient() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        try await s.setMapping(project: "p1", clientId: acme, billable: true)
        try await s.setMapping(project: "p2", clientId: vault, billable: true)
        let a1 = try await s.startActivity(source: "claude-code", externalId: "s1", project: "p1", title: nil, metadata: nil)
        let a2 = try await s.startActivity(source: "claude-code", externalId: "s2", project: "p2", title: nil, metadata: nil)
        try await focus(s, a1, 0, 100)
        try await focus(s, a2, 100, 200)

        let acmeResult = try await s.attributedSegments(from: 0, to: 1000, client: acme)
        #expect(acmeResult.segments.count == 1)
        #expect(acmeResult.segments[0].activityId == a1)

        let vaultResult = try await s.attributedSegments(from: 0, to: 1000, client: vault)
        #expect(vaultResult.segments.count == 1)
        #expect(vaultResult.segments[0].activityId == a2)
    }
}
