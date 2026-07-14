import Testing
@testable import KairosStore
import KairosCore

@Suite
struct SegmentsPipelineTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    @Test
    func explicitSegmentResolvesClient() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: true)
        let act = try await s.openActivity(source: "claude-code", externalId: "s1", project: "daemonclaw", title: "Build", metadata: nil, ts: 0)
        try await s.closeActivity(activityId: act, ts: 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.count == 1)
        #expect(result.segments[0] == Segment(activityId: act, start: 0, end: 3600, seconds: 3600, rule: "explicit"))
        #expect(result.activities[act]?.client.clientId == acme)
        #expect(result.activities[act]?.client.billable == true)
        #expect(result.activities[act]?.clientName == "Acme")
        #expect(result.activities[act]?.record.project == "daemonclaw")
        #expect(result.activities[act]?.record.source == "claude-code")
    }

    @Test
    func afkDoesNotReduceExplicitSegment() async throws {
        let s = try store()
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "Sync", metadata: nil, ts: 0)
        let src = try await s.resolveSource(slug: "meeting")
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 1200)
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOff, ts: 2400)
        try await s.closeActivity(activityId: act, ts: 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.count == 1)
        #expect(result.segments[0].seconds == 3600)   // afk immune
    }

    @Test
    func pauseHolesExplicitSegment() async throws {
        let s = try store()
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "Sync", metadata: nil, ts: 0)
        let src = try await s.resolveSource(slug: "meeting")
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .pauseOn, ts: 1800)
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .pauseOff, ts: 2400)
        try await s.closeActivity(activityId: act, ts: 3600)

        let result = try await s.attributedSegments(from: 0, to: 7200)
        #expect(result.segments.count == 2)
        #expect(result.segments.reduce(0) { $0 + $1.seconds } == 3000)   // 3600 - 600 pause
    }

    @Test
    func filterByClient() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        try await s.setMapping(project: "p1", clientId: acme, billable: true)
        try await s.setMapping(project: "p2", clientId: vault, billable: true)
        let a1 = try await s.openActivity(source: "claude-code", externalId: "s1", project: "p1", title: nil, metadata: nil, ts: 0)
        let a2 = try await s.openActivity(source: "claude-code", externalId: "s2", project: "p2", title: nil, metadata: nil, ts: 0)
        try await s.closeActivity(activityId: a1, ts: 100)
        try await s.closeActivity(activityId: a2, ts: 100)

        let acmeResult = try await s.attributedSegments(from: 0, to: 1000, client: acme)
        #expect(acmeResult.segments.count == 1)
        #expect(acmeResult.segments[0].activityId == a1)

        let vaultResult = try await s.attributedSegments(from: 0, to: 1000, client: vault)
        #expect(vaultResult.segments.count == 1)
        #expect(vaultResult.segments[0].activityId == a2)
    }
}
