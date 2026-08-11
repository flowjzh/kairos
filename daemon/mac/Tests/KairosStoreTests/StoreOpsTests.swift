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
            _ = try await s.startActivity(source: "claude-code", externalId: "sess-persist", project: "proj", title: nil, metadata: nil)
            _ = try await s.appendEvent(activityId: nil, kind: .afkOn, ts: 200)
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
        _ = try await writer.appendEvent(activityId: nil, kind: .afkOn, ts: 1)

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
        let id1 = try await s.appendEvent(activityId: nil, kind: .afkOn, ts: 1, payload: nil)
        let id2 = try await s.appendEvent(activityId: nil, kind: .afkOff, ts: 2, payload: nil)
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
    func startResumesAnArchivedActivity() async throws {
        let s = try store()
        let a = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        try await s.setActivityState(activityId: a, .archived)
        #expect(try await s.visibleActivities().isEmpty)
        let b = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        #expect(b == a)   // same row, made visible again
        #expect(try await s.visibleActivities().map(\.id) == [a])
    }

    @Test
    func manualStartCreatesDistinctActivities() async throws {
        let s = try store()
        let a = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Standup", metadata: nil)
        let b = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Standup", metadata: nil)
        #expect(a != b)   // NULL external_id → distinct activity rows
    }

    @Test
    func archiveHidesActivity() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        #expect(try await s.visibleActivities().count == 1)
        try await s.setActivityState(activityId: id, .archived)
        #expect(try await s.visibleActivities().isEmpty)
    }

    @Test
    func visibleManualActivitiesExcludesArchivedAndAuto() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "manual", externalId: nil, project: nil, title: "Sync", metadata: nil)
        try await s.setActivityState(activityId: id, .archived)
        #expect(try await s.visibleManualActivities().isEmpty)   // archived manual hidden
        // An auto activity is not a manual candidate.
        _ = try await s.startActivity(source: "claude-code", externalId: "x", project: nil, title: nil, metadata: nil)
        #expect(try await s.visibleManualActivities().isEmpty)
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
        let active = try await s.visibleActivities()
        #expect(active.count == 1)
        #expect(active[0].id == id)
        #expect(active[0].title == "客户会议")
        #expect(active[0].source == "manual")
    }

    @Test
    func resumeUpdatesTitleWhenGiven() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: "First", metadata: nil)
        // Resume with a new title → renames the existing row.
        _ = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: "Renamed", metadata: nil)
        #expect(try await s.loadActivity(id: id)?.title == "Renamed")
    }

    @Test
    func resumeWithoutTitlePreservesExistingTitle() async throws {
        let s = try store()
        let id = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: "Named", metadata: nil)
        // Resume with no title (e.g. `kairos claude` without `--title`) → keeps "Named".
        _ = try await s.startActivity(source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        #expect(try await s.loadActivity(id: id)?.title == "Named")
    }

    // adoptOrStart is the path the CC hook's activities.start actually takes
    // (Design B reconciliation) — title-on-resume must work here too, not just in
    // startActivity. Regression for the resume path that ships the title through.
    @Test
    func adoptOrStartResumeUpdatesTitle() async throws {
        let s = try store()
        _ = try await s.adoptOrStart(shellId: nil, source: "claude-code", externalId: "sess-1", project: nil, title: "First", metadata: nil)
        _ = try await s.adoptOrStart(shellId: nil, source: "claude-code", externalId: "sess-1", project: nil, title: "Renamed", metadata: nil)
        let id = try await s.findActivity(source: "claude-code", externalId: "sess-1")!
        #expect(try await s.loadActivity(id: id)?.title == "Renamed")
    }

    @Test
    func adoptOrStartResumeWithoutTitlePreserves() async throws {
        let s = try store()
        _ = try await s.adoptOrStart(shellId: nil, source: "claude-code", externalId: "sess-1", project: nil, title: "Named", metadata: nil)
        _ = try await s.adoptOrStart(shellId: nil, source: "claude-code", externalId: "sess-1", project: nil, title: nil, metadata: nil)
        let id = try await s.findActivity(source: "claude-code", externalId: "sess-1")!
        #expect(try await s.loadActivity(id: id)?.title == "Named")
    }
}
