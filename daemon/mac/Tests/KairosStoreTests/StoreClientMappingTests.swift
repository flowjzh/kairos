import Testing
@testable import KairosStore
import Foundation

@Suite
struct StoreClientMappingTests {
    private func store() throws -> Store { try Store(path: ":memory:") }

    // MARK: Clients

    @Test
    func addAndListClients() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        let clients = try await s.listClients()
        #expect(clients == [Client(id: acme, name: "Acme"), Client(id: vault, name: "Vault")])
    }

    @Test
    func listProjectsReturnsRegisteredSlugs() async throws {
        let s = try store()
        _ = try await s.resolveProject(slug: "beta")
        _ = try await s.resolveProject(slug: "alpha")
        _ = try await s.resolveProject(slug: "beta")   // idempotent
        #expect(try await s.listProjects() == ["alpha", "beta"])
    }

    @Test
    func renameClient() async throws {
        let s = try store()
        let id = try await s.addClient(name: "Acme")
        try await s.renameClient(id: id, name: "Acme Corp")
        #expect(try await s.listClients() == [Client(id: id, name: "Acme Corp")])
    }

    // MARK: Mapping

    @Test
    func setMappingAppendsAndResolvesLatest() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: true)
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: false)
        #expect(try await s.listMapping() == [ProjectMapping(project: "daemonclaw", clientId: acme, billable: false)])
    }

    @Test
    func mappingTombstoneUnmaps() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: true)
        try await s.setMapping(project: "daemonclaw", clientId: nil, billable: true)
        #expect(try await s.listMapping() == [ProjectMapping(project: "daemonclaw", clientId: nil, billable: true)])
    }

    // MARK: Resolution (override > map > unassigned)

    @Test
    func resolveClientViaMap() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        try await s.setMapping(project: "daemonclaw", clientId: acme, billable: true)
        let act = try await s.openActivity(source: "claude-code", externalId: "s1", project: "daemonclaw", title: nil, metadata: nil, ts: 0)
        let resolved = try await s.resolveClient(
            activityId: act,
            eventsWatermark: try await s.eventsWatermark(),
            mapWatermark: try await s.mapWatermark()
        )
        #expect(resolved == ResolvedClient(clientId: acme, billable: true))
    }

    @Test
    func resolveClientOverrideBeatsMap() async throws {
        let s = try store()
        let acme = try await s.addClient(name: "Acme")
        let vault = try await s.addClient(name: "Vault")
        try await s.setMapping(project: "proj", clientId: acme, billable: true)
        let act = try await s.openActivity(source: "meeting", externalId: nil, project: "proj", title: "Sync", metadata: nil, ts: 0)
        let payload = try JSONSerialization.data(withJSONObject: ["client_id": Int(vault), "billable": false])
        let src = try await s.resolveSource(slug: "meeting")
        _ = try await s.appendEvent(activityId: act, sourceId: src, kind: .activityOverride, ts: 1, payload: payload)
        let resolved = try await s.resolveClient(
            activityId: act,
            eventsWatermark: try await s.eventsWatermark(),
            mapWatermark: try await s.mapWatermark()
        )
        #expect(resolved == ResolvedClient(clientId: vault, billable: false))
    }

    @Test
    func resolveClientUnassignedWhenNoMap() async throws {
        let s = try store()
        let act = try await s.openActivity(source: "claude-code", externalId: "s1", project: "unmapped", title: nil, metadata: nil, ts: 0)
        let resolved = try await s.resolveClient(
            activityId: act,
            eventsWatermark: try await s.eventsWatermark(),
            mapWatermark: try await s.mapWatermark()
        )
        #expect(resolved == ResolvedClient(clientId: nil, billable: true))
    }

    // MARK: Watermark-bounded load (reproduce mechanism)

    @Test
    func loadEventsRespectsWatermark() async throws {
        let s = try store()
        let src = try await s.resolveSource(slug: "idle")
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 1, payload: nil)
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOff, ts: 2, payload: nil)
        let wm = try await s.eventsWatermark()
        _ = try await s.appendEvent(activityId: nil, sourceId: src, kind: .afkOn, ts: 3, payload: nil)
        #expect(try await s.loadEvents(upToWatermark: wm).count == 2)
        #expect(try await s.loadEvents().count == 3)
    }
}
