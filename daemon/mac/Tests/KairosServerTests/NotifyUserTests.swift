import Foundation
import Testing
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

/// Locked mutable cell, so a `@Sendable` closure can capture and mutate it
/// deterministically (Swift 6 forbids capturing a local `var` in a `@Sendable`
/// closure). Read after the awaited `handle` returns — the `notify` seam is
/// called synchronously inside the handler, so there is no race.
private final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ value: T) { self.value = value }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
}

@Suite
struct NotifyUserTests {
    private func env(_ method: KairosRPC.Method, _ params: JSONValue) -> RequestEnvelope {
        RequestEnvelope(method: method, params: params)
    }

    // MARK: NotificationGate

    @Test
    func gateAllowsFirstThenSuppressesWithinCooldown() async {
        let t = Box(Date(timeIntervalSince1970: 1000))
        let gate = NotificationGate(now: { t.get() })
        #expect(await gate.allow("k", cooldown: 60) == true)
        #expect(await gate.allow("k", cooldown: 60) == false)   // same key, within cooldown
        t.set(Date(timeIntervalSince1970: 1100))   // past the cooldown
        #expect(await gate.allow("k", cooldown: 60) == true)
    }

    @Test
    func gateKeysAreIndependent() async {
        let gate = NotificationGate()
        #expect(await gate.allow("a", cooldown: 60) == true)
        #expect(await gate.allow("b", cooldown: 60) == true)   // a different key is its own window
    }

    // MARK: notify.user handler

    @Test
    func notifyUserDeliversAndReturnsResult() async throws {
        let store = try Store(path: ":memory:")
        let rec = Box<[NotificationContent]>([])
        let d = Dispatcher(notify: { p in rec.set(rec.get() + [p]) })
        let params = NotifyUserParams(source: "claude-code", kind: "pty_recommended", title: "T", message: "M")
        let resp = await d.handle(env(.notifyUser, try Wire.encodeValue(params)), store: store, now: { 0.0 })

        if case .error(let e) = resp { Issue.record("unexpected error: \(e)"); return }
        let got = rec.get()
        #expect(got.count == 1)
        #expect(got[0].title == "T")
        #expect(got[0].message == "M")
    }

    @Test
    func notifyUserCooldownSuppressesRepeat() async throws {
        let store = try Store(path: ":memory:")
        let rec = Box<[NotificationContent]>([])
        let d = Dispatcher(notify: { p in rec.set(rec.get() + [p]) })
        let req = env(.notifyUser, try Wire.encodeValue(
            NotifyUserParams(source: "claude-code", kind: "pty_recommended", title: "T", message: "M", cooldownSeconds: 3600)
        ))
        _ = await d.handle(req, store: store, now: { 0.0 })
        _ = await d.handle(req, store: store, now: { 0.0 })   // same (source, kind) within the 3600 s cooldown
        #expect(rec.get().count == 1)
    }

    @Test
    func notifyUserWithoutCooldownAlwaysDelivers() async throws {
        let store = try Store(path: ":memory:")
        let rec = Box<[NotificationContent]>([])
        let d = Dispatcher(notify: { p in rec.set(rec.get() + [p]) })
        let req = env(.notifyUser, try Wire.encodeValue(
            NotifyUserParams(source: "claude-code", kind: "pty_recommended", title: "T", message: "M")   // no cooldown
        ))
        _ = await d.handle(req, store: store, now: { 0.0 })
        _ = await d.handle(req, store: store, now: { 0.0 })
        #expect(rec.get().count == 2)   // no cooldown → every call delivered (the plugin's behaviour)
    }
}
