import Foundation
import KairosCore
import KairosRPC
import KairosStore

/// Source slugs under which the daemon records its own (non-activity) events.
public enum DaemonSources {
    /// Manual control events (pause) from the menu bar / CLI.
    public static let control = "kairos"
    /// afk spans from the idle sampler.
    public static let idle = "idle"
}

/// Maps a line-JSON `RequestEnvelope` to `Store` operations and back. The only
/// daemon-scoped state is the `SessionRegistry` (the ephemeral kid→activity map
/// + AFK-immune set, M4/M4p3). Since M4p3 timing is `focus`/`blur` only:
/// `activities.start/stop` declare identity+lifecycle (no event), and the daemon
/// materialises auto-catch focus events on a foreground blur (docs/04).
public struct Dispatcher: Sendable {
    let sessions: SessionRegistry
    /// Cooldown gate for `notify.user` (per `(source, kind)`); ephemeral.
    let gate: NotificationGate
    /// User-facing notification seam (rendered by `KairosDaemon`): auto-catch
    /// (multiple backdrops) and plugin-initiated `notify.user`. Speaks the
    /// presentation type only — routing/throttle policy is resolved before this.
    let notify: @Sendable (NotificationContent) -> Void

    public init(
        sessions: SessionRegistry = SessionRegistry(),
        gate: NotificationGate = NotificationGate(),
        notify: @escaping @Sendable (NotificationContent) -> Void = { _ in }
    ) {
        self.sessions = sessions
        self.gate = gate
        self.notify = notify
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
        case .focusSet: return try await focusSet(request, store: store, now: now)
        case .activitiesStart: return try await activitiesStart(request, store: store)
        case .activitiesStop: return try await activitiesStop(request, store: store, now: now)
        case .activitiesEnsure: return try await activitiesEnsure(request, store: store, now: now)
        case .controlPause: return try await controlPause(request, store: store, now: now)
        case .clientsList: return try await clientsList(request, store: store)
        case .clientsAdd: return try await clientsAdd(request, store: store)
        case .clientsRename: return try await clientsRename(request, store: store)
        case .mappingList: return try await mappingList(request, store: store)
        case .mappingSet: return try await mappingSet(request, store: store)
        case .segmentsGet: return try await segmentsGet(request, store: store)
        case .focusedGet: return try await focusedGet(request, store: store, now: now)
        case .notifyUser: return try await notifyUser(request)
        }
    }

    // MARK: Ingest — events (ai_submit / ai_stop / activity_override)

    private func eventsPost(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: EventsPostParams.self)
        try rejectFuture(p.ts, now: now)
        guard let activity = p.activity, let externalId = activity.externalId else {
            throw RPCError(code: "bad_request", message: "events.post requires activity with source and external_id")
        }
        guard let activityId = try await store.findActivity(source: activity.source, externalId: externalId) else {
            throw RPCError(code: "bad_request", message: "activity not started")
        }
        guard let kind = EventKind(slug: p.kind) else {
            throw RPCError(code: "bad_request", message: "unknown kind: \(p.kind)")
        }
        let payload = p.payload.flatMap { try? Wire.data($0) }
        _ = try await store.appendActivityEvent(activityId: activityId, kind: kind, ts: p.ts, payload: payload)
        // Self-heal the kid map from any hook RPC (flushes a buffered launch focus).
        if let kid = p.kairosSessionId { try await registerKid(kid, activityId: activityId, store: store) }
        return try Wire.encodeValue(EmptyResult())
    }

    // MARK: Activities — identity + lifecycle (no timing event)

    private func activitiesStart(_ request: RequestEnvelope, store: Store) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ActivitiesStartParams.self)
        let metadata = p.metadata.flatMap { try? Wire.data($0) }
        // The plugin owns its source's display name (M4p3).
        if let name = p.sourceDisplayName { try? await store.setSourceDisplayName(slug: p.source, displayName: name) }

        // Design B: if the wrapper's ensure-create already mapped the kid to an
        // activity, hand its id to `adoptOrStart` — which adopts it as a shell
        // iff it is a different source, else resumes/starts as appropriate.
        var shellId: Int64?
        if let kid = p.kairosSessionId, let mapped = await sessions.resolve(kid) {
            shellId = mapped
        }
        let id = try await store.adoptOrStart(shellId: shellId, source: p.source, externalId: p.externalId, project: p.project, title: p.title, metadata: metadata)
        await sessions.setAfkImmune(id, p.afkImmune ?? false)
        if let kid = p.kairosSessionId { try await registerKid(kid, activityId: id, store: store) }
        return try Wire.encodeValue(ActivitiesStartResult(activityId: id))
    }

    private func activitiesStop(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ActivitiesStopParams.self)
        try rejectFuture(p.ts, now: now)
        let id: Int64
        if let kid = p.kairosSessionId, let mapped = await sessions.resolve(kid) {
            id = mapped
        } else if let source = p.source, let ext = p.externalId, let found = try await store.findActivity(source: source, externalId: ext) {
            id = found
        } else {
            throw RPCError(code: "bad_request", message: "activities.stop requires kairos_session_id or (source, external_id)")
        }
        // Stop first (so a later best-effort step can't leave it active), then
        // blur (which also auto-catches to a backdrop if it was focused).
        try await store.setActivityState(activityId: id, .stopped)
        await sessions.setAfkImmune(id, false)
        try await recordFocus(activityId: id, focused: false, ts: p.ts, store: store)
        return try Wire.encodeValue(EmptyResult())
    }

    /// The wrapper's post-launch (~5 s) call: create a `pty` activity ONLY if the
    /// kid is still unclaimed by a hook (idempotent). Covers `vim`/`ssh`.
    private func activitiesEnsure(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ActivitiesEnsureParams.self)
        try rejectFuture(p.ts, now: now)
        if let existing = await sessions.resolve(p.kairosSessionId) {
            return try Wire.encodeValue(ActivitiesStartResult(activityId: existing))  // claimed by a hook
        }
        // kid is an ephemeral in-memory routing key, not a real external id — a
        // pty activity has none, so it is created with external_id = NULL.
        let id = try await store.startActivity(source: p.source, externalId: nil, project: p.project, title: p.title, metadata: nil)
        try await registerKid(p.kairosSessionId, activityId: id, store: store)
        return try Wire.encodeValue(ActivitiesStartResult(activityId: id))
    }

    // MARK: Focus (M4p3 — the timing base)

    /// A focus transition from the `kairos` PTY wrapper. Resolve the kid to its
    /// activity and record `focus`/`blur`; if the mapping isn't known yet (the
    /// launch race) buffer it for flush on registration.
    private func focusReport(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: FocusReportParams.self)
        try rejectFuture(p.ts, now: now)
        if let activityId = await sessions.resolve(p.kairosSessionId) {
            try await recordFocus(activityId: activityId, focused: p.focused, ts: p.ts, store: store)
        } else {
            await sessions.buffer(p.kairosSessionId, focused: p.focused, ts: p.ts)
        }
        return try Wire.encodeValue(EmptyResult())
    }

    /// Manual focus switch from the menu (replaces `force_owner`).
    private func focusSet(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: FocusSetParams.self)
        try rejectFuture(p.ts, now: now)
        let id = try await requireActivity(source: p.source, externalId: p.externalId, store: store)
        try await recordFocus(activityId: id, focused: true, ts: p.ts, store: store)
        return try Wire.encodeValue(EmptyResult())
    }

    /// Append a `focus`/`blur`; on a foreground blur that leaves nobody focused,
    /// materialise an auto-catch `focus` on the active manual backdrop.
    private func recordFocus(activityId: Int64, focused: Bool, ts: Double, store: Store) async throws {
        try await store.appendActivityEvent(activityId: activityId, kind: focused ? .focus : .blur, ts: ts)
        guard !focused else { return }
        try? await autoCatch(blurred: activityId, ts: ts, store: store)   // best-effort; never abort the caller
    }

    /// Backdrop auto-catch (docs/04): after a foreground `blur` leaves the pointer
    /// at none, fall back to an active manual backdrop (1 → automatic;
    /// >1 → most-recently-focused + a notification). No-op if a manual activity
    /// was the one blurred, or a successor already holds focus.
    private func autoCatch(blurred: Int64, ts: Double, store: Store) async throws {
        // Cheap indexed guards first, so the common blur (an auto split with no
        // backdrop waiting) never scans the event log.
        guard try await !store.isActivityManual(activityId: blurred) else { return }
        let backdrops = try await store.activeManualActivities()
        guard !backdrops.isEmpty else { return }
        let events = try await store.loadGlobalEvents()
        guard GlobalState.reduce(events: events, to: ts).focused == nil else { return }
        let targetId = mostRecentlyFocused(backdrops.map(\.id), events: events) ?? backdrops.last!.id
        try await store.appendActivityEvent(activityId: targetId, kind: .focus, ts: ts)
        if backdrops.count > 1 {
            let title = backdrops.first { $0.id == targetId }?.title ?? "an activity"
            notify(NotificationContent(title: "Kairos", message: "Multiple active activities — focus switched to \(title)"))
        }
    }

    /// The candidate id whose latest `focus` event is most recent.
    private func mostRecentlyFocused(_ ids: [Int64], events: [Event]) -> Int64? {
        let idSet = Set(ids)
        var latest: [Int64: Double] = [:]
        for e in events where e.kind == .focus {
            if let a = e.activityId, idSet.contains(a) { latest[a] = max(latest[a] ?? -.infinity, e.ts) }
        }
        return latest.max { $0.value < $1.value }?.key
    }

    /// Register kid → activity and flush any focus buffered before the mapping.
    private func registerKid(_ kid: String, activityId: Int64, store: Store) async throws {
        if let pending = await sessions.register(kid, activityId: activityId) {
            try await recordFocus(activityId: activityId, focused: pending.focused, ts: pending.ts, store: store)
        }
    }

    // MARK: Control

    private func controlPause(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: ControlPauseParams.self)
        try rejectFuture(p.ts, now: now)
        let sourceId = try await store.resolveSource(slug: DaemonSources.control)
        _ = try await store.appendEvent(activityId: nil, sourceId: sourceId, kind: p.paused ? .pauseOn : .pauseOff, ts: p.ts)
        return try Wire.encodeValue(EmptyResult())
    }

    /// A plugin asks the daemon to nudge the user (e.g. the agent started without
    /// `kairos`, so focus/blur is missing). The plugin owns the wording; the
    /// daemon delivers a native notification. Throttling is opt-in per request:
    /// `cooldownSeconds` gates by `(source, kind)`; nil delivers every call.
    private func notifyUser(_ request: RequestEnvelope) async throws -> JSONValue {
        let p = try Wire.decodeValue(request.params, as: NotifyUserParams.self)
        let deliver = if let cooldown = p.cooldownSeconds {
            await gate.allow("\(p.source)|\(p.kind)", cooldown: cooldown)
        } else {
            true
        }
        if deliver { notify(NotificationContent(title: p.title, subtitle: p.subtitle, message: p.message)) }
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

    private func focusedGet(_ request: RequestEnvelope, store: Store, now: @Sendable () -> Double) async throws -> JSONValue {
        let events = try await store.loadGlobalEvents()
        guard let id = GlobalState.reduce(events: events, to: now()).focused,
              let record = try await store.loadActivity(id: id) else {
            return try Wire.encodeValue(FocusedGetResult(activity: nil))
        }
        return try Wire.encodeValue(FocusedGetResult(activity: FocusedActivity(
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
