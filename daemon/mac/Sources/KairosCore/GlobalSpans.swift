import Foundation

/// Global (activity-less) exclusion spans: afk and manual pause. afk holes ai
/// (M2); pause holes explicit and ai. Explicit is immune to afk (docs/04).
/// A thin reader over `GlobalState` (ADR 21) — the pairing logic lives there.
public struct GlobalSpans: Sendable, Equatable {
    public let afk: [Interval]
    public let pause: [Interval]

    public init(afk: [Interval] = [], pause: [Interval] = []) {
        self.afk = afk
        self.pause = pause
    }

    /// Pair afk_on/off and pause_on/off; an open span extends to `to`.
    public static func extract(events: [Event], to: Double) -> GlobalSpans {
        let state = GlobalState.reduce(events: events, to: to)
        return GlobalSpans(afk: state.afk, pause: state.pause)
    }
}
