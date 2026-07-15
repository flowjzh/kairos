import Foundation
import Testing
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

/// Backdrop auto-catch (issue 3): when a foreground activity blurs and leaves
/// nobody focused, the daemon falls back to an active manual backdrop — and with
/// more than one, it picks the **most-recently-focused** one (the user's last
/// explicit intent), not a random/last-inserted row, notifying when ambiguous.
@Suite struct AutoCatchTests {
    private let now: @Sendable () -> Double = { 1_000_000 }

    private func env(_ method: KairosRPC.Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }

    private func startManual(_ d: Dispatcher, _ store: Store, _ ext: String) async throws {
        _ = await d.handle(env(.activitiesStart, try Wire.encodeValue(
            ActivitiesStartParams(source: "manual", externalId: ext, project: nil,
                                  title: nil, metadata: nil, kairosSessionId: nil))), store: store, now: now)
    }

    private func focus(_ d: Dispatcher, _ store: Store, _ ext: String, _ ts: Double) async throws {
        _ = await d.handle(env(.focusSet, try Wire.encodeValue(
            FocusSetParams(source: "manual", externalId: ext, ts: ts))), store: store, now: now)
    }

    private func pty(_ d: Dispatcher, _ store: Store, kid: String, focused: Bool, ts: Double) async throws {
        _ = await d.handle(env(.activitiesEnsure, try Wire.encodeValue(
            ActivitiesEnsureParams(kairosSessionId: kid, source: "pty", project: nil, title: nil, ts: ts))), store: store, now: now)
        _ = await d.handle(env(.focusReport, try Wire.encodeValue(
            FocusReportParams(kairosSessionId: kid, focused: focused, ts: ts))), store: store, now: now)
    }

    private func focused(_ store: Store, _ ts: Double) async throws -> Int64? {
        GlobalState.reduce(events: try await store.loadGlobalEvents(), to: ts).focused
    }

    private func manualId(_ store: Store, _ ext: String) async throws -> Int64? {
        try await store.findActivity(source: "manual", externalId: ext)
    }

    @Test func picksMostRecentlyFocusedNotLastInserted() async throws {
        let d = Dispatcher()
        let store = try Store(path: ":memory:")
        try await startManual(d, store, "m1")          // inserted first
        try await startManual(d, store, "m2")          // inserted second (activeManualActivities last)
        try await focus(d, store, "m2", now() + 1)     // focused earlier
        try await focus(d, store, "m1", now() + 2)     // focused later → most recent
        try await pty(d, store, kid: "k1", focused: true, ts: now() + 3)
        try await pty(d, store, kid: "k1", focused: false, ts: now() + 4)   // blur → auto-catch

        // m1 is the most-recently-focused backdrop, NOT m2 (last inserted).
        #expect(try await focused(store, now() + 4) == manualId(store, "m1"))
    }

    @Test func notifiesOnlyWhenMoreThanOneBackdrop() async throws {
        let rec = Notifications()
        let d = Dispatcher(notify: { rec.append($0) })

        // Two backdrops → ambiguous → notify once.
        let store2 = try Store(path: ":memory:")
        try await startManual(d, store2, "m1"); try await startManual(d, store2, "m2")
        try await focus(d, store2, "m1", now() + 1)
        try await pty(d, store2, kid: "k1", focused: true, ts: now() + 2)
        try await pty(d, store2, kid: "k1", focused: false, ts: now() + 3)
        #expect(rec.all.count == 1)

        // One backdrop → unambiguous → no extra notify.
        let store1 = try Store(path: ":memory:")
        try await startManual(d, store1, "only")
        try await focus(d, store1, "only", now() + 1)
        try await pty(d, store1, kid: "k2", focused: true, ts: now() + 2)
        try await pty(d, store1, kid: "k2", focused: false, ts: now() + 3)
        #expect(rec.all.count == 1)
    }

    @Test func noBackdropLeavesPointerAtNone() async throws {
        let d = Dispatcher()
        let store = try Store(path: ":memory:")
        try await pty(d, store, kid: "k1", focused: true, ts: now() + 1)
        try await pty(d, store, kid: "k1", focused: false, ts: now() + 2)
        #expect(try await focused(store, now() + 2) == nil)   // nothing to catch to
    }
}

/// Sync-safe collector for the `notify` closure (which is synchronous).
private final class Notifications: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [NotificationContent] = []
    func append(_ c: NotificationContent) { lock.lock(); items.append(c); lock.unlock() }
    var all: [NotificationContent] { lock.lock(); defer { lock.unlock() }; return items }
}
