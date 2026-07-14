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
            _ = try await s.openActivity(source: "claude-code", externalId: "sess-persist", project: "proj", title: nil, metadata: nil, ts: 100)
            _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 200)
            #expect(try await s.eventsWatermark() == 2)
        }   // s deinits here → connection closes

        let reopened = try Store(path: path)
        #expect(try await reopened.eventsWatermark() == 2)
        #expect(try await reopened.findActivity(source: "claude-code", externalId: "sess-persist") != nil)
    }

    @Test
    func writesCommitImmediatelyToDisk() async throws {
        // A write must be committed (durable) as soon as the call returns, not
        // only on clean close. A second connection to the same file must see it
        // while the first is still open. Guards against statements parked
        // mid-transaction (e.g. INSERT…RETURNING stepped once) never committing.
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
    func resolveProjectIsIdempotent() async throws {
        let s = try store()
        let a = try await s.resolveProject(slug: "daemonclaw")
        let b = try await s.resolveProject(slug: "daemonclaw")
        #expect(a == b)
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
    func openActivityIsIdempotentOnSourceExternalId() async throws {
        let s = try store()
        let a = try await s.openActivity(source: "claude-code", externalId: "sess-1", project: "daemonclaw", title: "t", metadata: nil, ts: 10)
        let wm1 = try await s.eventsWatermark()
        let b = try await s.openActivity(source: "claude-code", externalId: "sess-1", project: "daemonclaw", title: "t", metadata: nil, ts: 10)
        let wm2 = try await s.eventsWatermark()
        #expect(a == b)
        #expect(wm1 == wm2)   // re-open is a no-op: no duplicate activity_open event
    }

    @Test
    func openMeetingCreatesDistinctActivities() async throws {
        let s = try store()
        let a = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "Standup", metadata: nil, ts: 10)
        let b = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "Standup", metadata: nil, ts: 20)
        #expect(a != b)   // NULL external_id → distinct activity rows
    }

    @Test
    func closeActivityEmitsCloseEvent() async throws {
        let s = try store()
        let id = try await s.openActivity(source: "meeting", externalId: nil, project: nil, title: "Sync", metadata: nil, ts: 10)
        let before = try await s.eventsWatermark()
        try await s.closeActivity(activityId: id, ts: 20)
        #expect(try await s.eventsWatermark() == before + 1)
    }

    @Test
    func findActivityBySourceExternalId() async throws {
        let s = try store()
        let id = try await s.openActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil, ts: 10)
        #expect(try await s.findActivity(source: "claude-code", externalId: "sess-1") == id)
        #expect(try await s.findActivity(source: "claude-code", externalId: "missing") == nil)
    }

    @Test
    func openActivityPreservesCJKTitle() async throws {
        // The exact path the config window uses: open with a non-ASCII title,
        // read it back via openActivities. UTF-8 must round-trip.
        let s = try store()
        let id = try await s.openActivity(source: "manual", externalId: nil, project: nil, title: "客户会议", metadata: nil, ts: 10)
        let open = try await s.openActivities()
        #expect(open.count == 1)
        #expect(open[0].id == id)
        #expect(open[0].title == "客户会议")
        #expect(open[0].source == "manual")
    }
}
