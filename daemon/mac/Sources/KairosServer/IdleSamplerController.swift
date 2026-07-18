import AppKit
import CoreGraphics
import Foundation
import KairosCore
import KairosRPC
import KairosStore

/// The resident idle sampler (docs/06). Polls `CGEventSource` on a timer and
/// subscribes to `NSWorkspace` sleep/wake; the pure `IdleSampler` decides
/// transitions, which are appended to the store as afk events. The macOS-API
/// polling is a system boundary (manual smoke); the logic is in `IdleSampler`.
public final class IdleSamplerController: @unchecked Sendable {
    private let store: Store
    private let sessions: SessionRegistry?
    private let pollInterval: Double
    private let queue = DispatchQueue(label: "kairos.idle")
    private var state = IdleSampler.State()
    private var timer: DispatchSourceTimer?
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    public init(store: Store, sessions: SessionRegistry? = nil, pollInterval: Double = 5) {
        self.store = store
        self.sessions = sessions
        self.pollInterval = pollInterval
    }

    public func start() async {
        let now = Date().timeIntervalSince1970
        let lastTs = try? await store.lastEventTs()
        let lastAfkOpen = (try? await store.lastAfkEventKind()) == .afkOn
        for transition in IdleSampler.startupGap(lastEventTs: lastTs, lastAfkOpen: lastAfkOpen, now: now, pollInterval: pollInterval) {
            await append(transition)
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer

        let center = NSWorkspace.shared.notificationCenter
        let opQueue = OperationQueue()
        opQueue.underlyingQueue = queue
        opQueue.maxConcurrentOperationCount = 1
        sleepObserver = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: opQueue) { [weak self] _ in
            self?.apply(.sleep)
        }
        wakeObserver = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: opQueue) { [weak self] _ in
            self?.apply(.wake)
        }
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
    }

    private func poll() {
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInputEventType)
        let now = Date().timeIntervalSince1970
        let (next, events) = IdleSampler.sample(state: state, idleSeconds: idle, now: now, threshold: AppSettings.idleThreshold, pollInterval: pollInterval)
        state = next
        for event in events { Task { await self.append(event) } }
    }

    private enum Signal { case sleep, wake }

    private func apply(_ signal: Signal) {
        let now = Date().timeIntervalSince1970
        let (next, events): (IdleSampler.State, [IdleTransition])
        switch signal {
        case .sleep: (next, events) = IdleSampler.sleep(state: state, ts: now)
        case .wake: (next, events) = IdleSampler.wake(state: state, ts: now)
        }
        state = next
        for event in events { Task { await self.append(event) } }
    }

    private func append(_ transition: IdleTransition) async {
        switch transition {
        case .afkOn(let reason, let ts):
            if await focusedIsAfkImmune(at: ts) { return }  // passive activity: no afk to deduct
            let payload = try? Wire.data(AfkOnPayload(reason: reason.rawValue))
            _ = try? await store.appendEvent(activityId: nil, kind: .afkOn, ts: ts, payload: payload)
        case .afkOff(let ts):
            _ = try? await store.appendEvent(activityId: nil, kind: .afkOff, ts: ts)
        }
    }

    /// True when the currently focused activity was started AFK-immune — the
    /// idle sampler then suppresses `afk_on` (ADR 33), so the log has no span.
    private func focusedIsAfkImmune(at ts: Double) async -> Bool {
        guard let sessions, let events = try? await store.loadGlobalEvents(since: ts - Store.liveWindow),
              let focused = GlobalState.reduce(events: events, to: ts).focused else { return false }
        return await sessions.isAfkImmune(focused)
    }
}

/// `kCGAnyInputEventType` (~0) — seconds since any input. Not imported as a
/// named `CGEventType` in Swift.
private let anyInputEventType = CGEventType(rawValue: ~UInt32(0))!
