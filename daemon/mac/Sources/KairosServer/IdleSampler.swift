import Foundation
import KairosCore

/// Why an afk span began (docs/06): idle timeout, system sleep, or a
/// daemon-down/machine-off gap detected at startup. **Storage is the `Int`
/// rawValue** (in the `afk_on` payload), the same code-vs-slug split as
/// `EventKind`/`ActivityState`.
public enum IdleReason: Int, Sendable {
    case idle = 0, sleep = 1, offline = 2
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
        /// What opened the current afk span, if any. A `sleep` span (lid close /
        /// `willSleep`) is closed by `wake` — or, if the machine never actually
        /// slept, by the idle poll once input resumes — but NOT by the idle poll
        /// the instant the lid closes, when idle time is still near zero.
        public enum Afk: Sendable, Equatable { case none, idle, sleep }
        public var afk: Afk
        /// During a `sleep` span, whether idle has since crossed the threshold.
        /// Guards the aborted-sleep case: the poll may close a sleep span only
        /// after the machine has actually gone quiet, so a just-closed-lid poll
        /// (idle ≈ 0) can't cancel it.
        public var sleepIdled: Bool
        /// Timestamp of the previous poll. A jump far larger than the poll
        /// interval means the process was suspended (system sleep) with no poll
        /// in between; the gap is backfilled as afk so a sleep that delivered no
        /// `willSleep` is still holed (idle auto-sleep often doesn't deliver one).
        public var lastPoll: Double?

        public init(afk: Afk = .none, sleepIdled: Bool = false, lastPoll: Double? = nil) {
            self.afk = afk
            self.sleepIdled = sleepIdled
            self.lastPoll = lastPoll
        }

        public var isAfk: Bool { afk != .none }
    }

    /// One idle poll, in order: (1) a suspend/resume gap — the poll timer was
    /// frozen across a system sleep — is backfilled as afk; (2) idle crossing
    /// the threshold opens/closes an idle span; (3) a `sleep` span (from
    /// `willSleep`) closes once the machine has gone quiet and input resumes,
    /// but is immune to the fresh-lid-close cancel (idle ≈ 0 right after).
    public static func sample(state: State, idleSeconds: Double, now: Double,
                              threshold: Double, pollInterval: Double) -> (State, [IdleTransition]) {
        var next = state
        var events: [IdleTransition] = []

        if let last = state.lastPoll, now - last > max(threshold, pollInterval) {
            if !next.isAfk {
                // Suspended while not afk: nothing covered the gap — backfill it.
                events.append(.afkOn(reason: .offline, ts: last))
                next.afk = .idle
            } else if next.afk == .sleep {
                // The suspension confirms a real sleep, so a resuming active poll
                // may now close the span (guard below).
                next.sleepIdled = true
            }
        }
        next.lastPoll = now

        switch next.afk {
        case .none:
            if idleSeconds >= threshold {
                next.afk = .idle
                events.append(.afkOn(reason: .idle, ts: now))
            }
        case .idle:
            if idleSeconds < threshold {
                next = State(lastPoll: now)
                events.append(.afkOff(ts: now))
            }
        case .sleep:
            if idleSeconds >= threshold {
                next.sleepIdled = true
            } else if next.sleepIdled {
                next = State(lastPoll: now)
                events.append(.afkOff(ts: now))
            }
        }
        return (next, events)
    }

    /// System sleep → afk_on{sleep} (unless already afk). Keeps `lastPoll` so a
    /// sleep with no matching `wake` is still reconciled by the next poll's gap.
    public static func sleep(state: State, ts: Double) -> (State, [IdleTransition]) {
        guard state.afk == .none else { return (state, []) }
        return (State(afk: .sleep, lastPoll: state.lastPoll), [.afkOn(reason: .sleep, ts: ts)])
    }

    /// System wake → afk_off (if afk), whatever opened the span. Advances
    /// `lastPoll` to the wake instant so the next poll doesn't also backfill the
    /// just-closed sleep as a gap.
    public static func wake(state: State, ts: Double) -> (State, [IdleTransition]) {
        guard state.isAfk else { return (state, []) }
        return (State(lastPoll: ts), [.afkOff(ts: ts)])
    }

    /// Startup gap (daemon/machine was down): emit afk_on{offline}@lastEvent …
    /// afk_off@now so the gap holes ai windows across it (M2). No-op if no gap.
    public static func startupGap(lastEventTs: Double?, now: Double, pollInterval: Double) -> [IdleTransition] {
        guard let last = lastEventTs, now - last > pollInterval else { return [] }
        return [.afkOn(reason: .offline, ts: last), .afkOff(ts: now)]
    }
}
