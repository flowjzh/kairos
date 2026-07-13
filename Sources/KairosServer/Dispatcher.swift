import Foundation
import KairosCore
import KairosRPC
import KairosStore

/// Source slugs under which the daemon records its own (non-client) events.
public enum DaemonSources {
    /// Manual control events (pause/force_owner) from the menu bar / CLI.
    public static let control = "kairos"
    /// afk spans from the idle sampler.
    public static let idle = "idle"
}

/// Maps a line-JSON `RequestEnvelope` to `Store` operations and back to a
/// `ResponseEnvelope`. Per-request state comes from the injected `Store`; the
/// only daemon-scoped state it carries is the `SessionRegistry` (the ephemeral
/// `kairos-pty` focus map, M4). `events.post` requires an activity
/// `{source, external_id}` — global events (afk) are written by the daemon
/// internally, and pause uses `control.pause`.
public struct Dispatcher: Sendable {
    /// Ephemeral `KAIROS_SESSION_ID → activity` map for M4 focus reports; shared
    /// across every request through the single daemon-held `Dispatcher`.
    let sessions: SessionRegistry

    public init(sessions: SessionRegistry = SessionRegistry()) {
        self.sessions = sessions
    }

    public func handle(
        _ request: RequestEnvelope,
        store: Store,
        now: @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async -> ResponseEnvelope {
        do {
            return .result(try await dispatch(request, store: store, now: now))
        } catch let error as RPCError {
            return .error(error)
        } catch StoreError.notFound(let what) {
            return .error(RPCError(code: "not_found", message: what))
        } catch {
            return .error(RPCError(code: "internal", message: String(describing: error)))
        }
    }

    private func dispatch(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        switch request.method {
        case .eventsPost: return try await eventsPost(request, store: store, now: now)
        case .focusReport: return try await focusReport(request, store: store, now: now)
        case .activitiesOpen: return try await activitiesOpen(request, store: store, now: now)
        case .activitiesClose: return try await activitiesClose(request, store: store, now: now)
        case .controlPause: return try await controlPause(request, store: store, now: now)
        case .controlOwner: return try await controlOwner(request, store: store, now: now)
        case .clientsList: return try await clientsList(request, store: store)
        case .clientsAdd: return try await clientsAdd(request, store: store)
        case .clientsRename: return try await clientsRename(request, store: store)
        case .mappingList: return try await mappingList(request, store: store)
        case .mappingSet: return try await mappingSet(request, store: store)
        case .segmentsGet: return try await segmentsGet(request, store: store)
        case .ownerGet: return try await ownerGet(request, store: store)
        }
    }

    // MARK: Ingest

    private func eventsPost(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: EventsPostParams.self)
        try rejectFuture(p.ts, now: now)
        guard let activity = p.activity, let externalId = activity.externalId else {
            throw RPCError(code: "bad_request", message: "events.post requires activity with source and external_id")
        }
        guard let activityId = try await store.findActivity(source: activity.source, externalId: externalId) else {
            throw RPCError(code: "bad_request", message: "activity not opened")
        }
        guard let kind = EventKind(rawValue: p.kind) else {
            throw RPCError(code: "bad_request", message: "unknown kind: \(p.kind)")
        }
        let sourceId = try await store.resolveSource(slug: activity.source)
        let payload = p.payload.flatMap { try? Wire.data($0) }
        _ = try await store.appendEvent(activityId: activityId, sourceId: sourceId, kind: kind, ts: p.ts, payload: payload)
        await registerSession(p.kairosSessionId, source: activity.source, externalId: externalId, store: store)
        return try Wire.encodeValue(EmptyResult())
    }

    private func activitiesOpen(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ActivitiesOpenParams.self)
        let metadata = p.metadata.flatMap { try? Wire.data($0) }
        let id = try await store.openActivity(source: p.source, externalId: p.externalId, project: p.project, title: p.title, metadata: metadata, ts: now())
        await registerSession(p.kairosSessionId, source: p.source, externalId: p.externalId, store: store)
        return try Wire.encodeValue(ActivitiesOpenResult(activityId: id))
    }

    private func activitiesClose(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ActivitiesCloseParams.self)
        try rejectFuture(p.ts, now: now)
        let id = try await requireActivity(source: p.source, externalId: p.externalId, store: store)
        try await store.closeActivity(activityId: id, ts: p.ts)
        await registerSession(p.kairosSessionId, source: p.source, externalId: p.externalId, store: store)
        return try Wire.encodeValue(EmptyResult())
    }

    // MARK: Focus (M4)

    /// A focus transition from `kairos-pty`. Resolve the wrapper session to its
    /// activity and append `ai_focus`/`ai_blur`; if the mapping isn't known yet
    /// (the report beat the first hook), buffer it for flush on registration.
    private func focusReport(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: FocusReportParams.self)
        try rejectFuture(p.ts, now: now)
        if let target = await sessions.resolve(p.kairosSessionId) {
            try await appendFocus(target, focused: p.focused, ts: p.ts, store: store)
        } else {
            await sessions.buffer(p.kairosSessionId, focused: p.focused, ts: p.ts)
        }
        return try Wire.encodeValue(EmptyResult())
    }

    /// Refresh the `kairos-pty` mapping from a hook RPC, flushing any focus that
    /// arrived before the mapping was known. No-op when unwrapped or `externalId`
    /// is absent.
    private func registerSession(_ kairosSessionId: String?, source: String, externalId: String?, store: Store) async {
        guard let kairosSessionId, let externalId else { return }
        guard let pending = await sessions.register(kairosSessionId, source: source, externalId: externalId) else { return }
        try? await appendFocus(SessionRegistry.Target(source: source, externalId: externalId), focused: pending.focused, ts: pending.ts, store: store)
    }

    private func appendFocus(_ target: SessionRegistry.Target, focused: Bool, ts: Double, store: Store) async throws {
        guard let activityId = try await store.findActivity(source: target.source, externalId: target.externalId) else { return }
        let sourceId = try await store.resolveSource(slug: target.source)
        _ = try await store.appendEvent(activityId: activityId, sourceId: sourceId, kind: focused ? .aiFocus : .aiBlur, ts: ts)
    }

    // MARK: Control

    private func controlPause(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ControlPauseParams.self)
        try rejectFuture(p.ts, now: now)
        let sourceId = try await store.resolveSource(slug: DaemonSources.control)
        _ = try await store.appendEvent(activityId: nil, sourceId: sourceId, kind: p.paused ? .pauseOn : .pauseOff, ts: p.ts)
        return try Wire.encodeValue(EmptyResult())
    }

    private func controlOwner(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ControlOwnerParams.self)
        try rejectFuture(p.ts, now: now)
        let id = try await requireActivity(source: p.source, externalId: p.externalId, store: store)
        let sourceId = try await store.resolveSource(slug: p.source)
        _ = try await store.appendEvent(activityId: id, sourceId: sourceId, kind: .forceOwner, ts: p.ts)
        return try Wire.encodeValue(EmptyResult())
    }

    /// Resolve `(source, external_id)` to an activity id, or bad_request.
    private func requireActivity(source: String, externalId: String?, store: Store) async throws -> Int64 {
        guard let externalId, let id = try await store.findActivity(source: source, externalId: externalId) else {
            throw RPCError(code: "bad_request", message: "activity not found")
        }
        return id
    }

    // MARK: Config

    private func clientsList(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let clients = try await store.listClients()
        return try Wire.encodeValue(ClientsListResult(clients: clients.map { ClientEntry(id: $0.id, name: $0.name) }))
    }

    private func clientsAdd(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ClientsAddParams.self)
        let id = try await store.addClient(name: p.name)
        return try Wire.encodeValue(ClientsAddResult(id: id))
    }

    private func clientsRename(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ClientsRenameParams.self)
        do {
            try await store.renameClient(id: p.id, name: p.name)
        } catch StoreError.notFound {
            throw RPCError(code: "not_found", message: "client \(p.id)")
        }
        return try Wire.encodeValue(EmptyResult())
    }

    private func mappingList(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let map = try await store.listMapping()
        return try Wire.encodeValue(MappingListResult(map: map.map { MappingEntry(project: $0.project, clientId: $0.clientId, billable: $0.billable) }))
    }

    private func mappingSet(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: MappingSetParams.self)
        try await store.setMapping(project: p.project, clientId: p.clientId, billable: p.billable)
        return try Wire.encodeValue(EmptyResult())
    }

    // MARK: Read

    private func segmentsGet(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: SegmentsGetParams.self)
        let result = try await store.attributedSegments(from: p.from, to: p.to, project: p.project, client: p.client)

        let wireSegments = result.segments.map {
            WireSegment(activityId: $0.activityId, start: $0.start, end: $0.end, seconds: $0.seconds, rule: $0.rule)
        }
        var wireActivities: [String: WireActivity] = [:]
        for (id, detail) in result.activities {
            let client = detail.client.clientId.map { WireClient(id: $0, name: detail.clientName ?? "") }
            var metadata: [String: JSONValue]?
            if let data = detail.record.metadata,
               let json = try? Wire.decode(jsonData: data),
               case .object(let dict) = json {
                metadata = dict
            }
            wireActivities[String(id)] = WireActivity(
                source: detail.record.source,
                externalId: detail.record.externalId,
                project: detail.record.project,
                title: detail.record.title,
                client: client,
                billable: detail.client.billable,
                metadata: metadata
            )
        }
        return try Wire.encodeValue(SegmentsGetResult(segments: wireSegments, activities: wireActivities))
    }

    private func ownerGet(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let events = try await store.loadEvents()
        guard let id = OwnerPredictor.predict(events: events),
              let record = try await store.loadActivity(id: id) else {
            return try Wire.encodeValue(OwnerGetResult(activity: nil))
        }
        return try Wire.encodeValue(OwnerGetResult(activity: OwnerActivity(
            source: record.source,
            externalId: record.externalId,
            project: record.project,
            title: record.title
        )))
    }

    // MARK: Helpers

    private func rejectFuture(_ ts: Double, now: @Sendable () -> Double) throws {
        if ts > now() + 60 {
            throw RPCError(code: "bad_request", message: "ts in the future")
        }
    }
}
