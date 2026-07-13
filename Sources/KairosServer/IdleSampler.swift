import Foundation
import KairosCore

/// Why an afk span began (docs/06): idle timeout, system sleep, or a
/// daemon-down/machine-off gap detected at startup.
public enum IdleReason: String, Sendable {
    case idle, sleep, offline
}

/// A transition the sampler wants recorded as an event.
public enum IdleTransition: Sendable, Equatable {
    case afkOn(reason: IdleReason, ts: Double)
    case afkOff(ts: Double)
}

/// Pure idle-sampler transitions. The polling shell (CGEventSource /
/// NSWorkspace) feeds samples into these; they decide which afk events to
/// emit and how the afk state changes. Tested in isolation.
public enum IdleSampler {
    public struct State: Sendable, Equatable {
        public var wasAfk: Bool
        public init(wasAfk: Bool = false) { self.wasAfk = wasAfk }
    }

    /// Idle crossing the threshold: afk_on{idle} upward, afk_off downward.
    public static func sample(state: State, idleSeconds: Double, now: Double, threshold: Double) -> (State, [IdleTransition]) {
        var next = state
        var events: [IdleTransition] = []
        if !next.wasAfk && idleSeconds >= threshold {
            events.append(.afkOn(reason: .idle, ts: now))
            next.wasAfk = true
        } else if next.wasAfk && idleSeconds < threshold {
            events.append(.afkOff(ts: now))
            next.wasAfk = false
        }
        return (next, events)
    }

    /// System sleep → afk_on{sleep} (unless already afk).
    public static func sleep(state: State, ts: Double) -> (State, [IdleTransition]) {
        guard !state.wasAfk else { return (state, []) }
        return (State(wasAfk: true), [.afkOn(reason: .sleep, ts: ts)])
    }

    /// System wake → afk_off (if afk).
    public static func wake(state: State, ts: Double) -> (State, [IdleTransition]) {
        guard state.wasAfk else { return (state, []) }
        return (State(wasAfk: false), [.afkOff(ts: ts)])
    }

    /// Startup gap (daemon/machine was down): emit afk_on{offline}@lastEvent …
    /// afk_off@now so the gap holes ai windows across it (M2). No-op if no gap.
    public static func startupGap(lastEventTs: Double?, now: Double, pollInterval: Double) -> [IdleTransition] {
        guard let last = lastEventTs, now - last > pollInterval else { return [] }
        return [.afkOn(reason: .offline, ts: last), .afkOff(ts: now)]
    }
}
