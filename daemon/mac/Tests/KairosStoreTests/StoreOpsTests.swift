import Testing
import Foundation
@testable import KairosStore
import KairosCore

@Suite
struct StoreOpsTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    @Test
    func dataPersistsAcrossReopen() async throws {
        // A file-backed store must survive close + reopen (durability).
        let path = NSTemporaryDirectory() + "kairos-persist-\(UUID().uuidString).db"
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + suffix) } }

        do {
            let s = try Store(path: path)
            let src = try await s.resolveSource(slug: "claude-code")
            _ = try await s.startActivity(source: "claude-code", externalId: "sess-persist", project: "proj", title: nil, metadata: nil)
            _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 200)
            #expect(try await s.eventsWatermark() == 1)   // start writes no event; only afk_on
        }   // s deinits here → connection closes

        let reopened = try Store(path: path)
        #expect(try await reopened.eventsWatermark() == 1)
        #expect(try await reopened.findActivity(source: "claude-code", externalId: "sess-persist") != nil)
    }

    @Test
    func writesCommitImmediatelyToDisk() async throws {
        let path = NSTemporaryDirectory() + "kairos-commit-\(UUID().uuidString).db"
        defer { for s in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path + s) } }

        let writer = try Store(path: path)
        let src = try await writer.resolveSource(slug: "claude-code")
        _ = try await writer.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 1)

        let reader = try Store(path: path)   // separate connection; writer still open
        #expect(try await reader.eventsWatermark() == 1)
    }

    @Test
    func resolveSourceIsIdempotent() async throws {
        let s = try store()
        let a = try await s.resolveSource(slug: "claude-code")
        let b = try await s.resolveSource(slug: "claude-code")
        #expect(a == b)
        let c = try await s.resolveSource(slug: "cursor")
        #expect(c != a)
    }

    @Test
    func appendEventReturnsMonotonicIds() async throws {
        let s = try store()
        let src = try await s.resolveSource(slug: "idle")
        let id1 = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 1, payload: nil)
        let id2 = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOff, ts: 2, payload: nil)
        #expect(id2 == id1 + 1)
        #expect(try await s.eventsWatermark() == id2)
    }

    @Test
    func startActivityIsIdempotentAndWritesNoEvent() async throws {
        let s = try store()
        let a = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: "daemonclaw", title: "t", metadata: nil)
        let b = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: "daemonclaw", title: "t", metadata: nil)
        #expect(a == b)
        #expect(try await s.eventsWatermark() == 0)   // pure identity/lifecycle, no event
    }

    @Test
    func startResumesAStoppedActivity() async throws {
        let s = try store()
        let a = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        try await s.setActivityState(activityId: a, .stopped)
        #expect(try await s.activeActivities().isEmpty)
        let b = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        #expect(b == a)   // same row, reactivated
        #expect(try await s.activeActivities().map(\.id) == [a])
    }

    @Test
    func manualStartCreatesDistinctActivities() async throws {
        let s = try store()
        let a = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Standup", metadata: nil)
        let b = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Standup", metadata: nil)
        #expect(a != b)   // NULL external_id → distinct activity rows
    }

    @Test
    func stopSetsStoppedState() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        #expect(try await s.activeActivities().count == 1)
        try await s.setActivityState(activityId: id, .stopped)
        #expect(try await s.activeActivities().isEmpty)
    }

    @Test
    func stoppedManualListedForReactivation() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        try await s.setActivityState(activityId: id, .stopped)
        #expect(try await s.recentStoppedManualActivities().map(\.id) == [id])
        // An auto (pty/claude) stopped activity is NOT offered for menu reactivation.
        let auto = try await s.startActivity(source: "claude-code", externalId: "x", project: nil, title: nil, metadata: nil)
        try await s.setActivityState(activityId: auto, .stopped)
        #expect(try await s.recentStoppedManualActivities().map(\.id) == [id])
    }

    @Test
    func findActivityBySourceExternalId() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        #expect(try await s.findActivity(source: "claude-code", externalId: "sess-1") == id)
        #expect(try await s.findActivity(source: "claude-code", externalId: "missing") == nil)
    }

    @Test
    func startPreservesCJKTitle() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "客户会议", metadata: nil)
        let active = try await s.activeActivities()
        #expect(active.count == 1)
        #expect(active[0].id == id)
        #expect(active[0].title == "客户会议")
        #expect(active[0].source == "manual")
    }
}
