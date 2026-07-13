import Foundation

/// A single ai human-work window before cross-activity resolution (docs/04 §B).
/// `submitTs` is the closing submit (the priority key: earlier submit wins);
/// `forced` marks a `force_owner` window, which claims ahead of all submits.
public struct AiWindow: Sendable, Equatable {
    public let activityId: Int64
    public let interval: Interval
    public let submitTs: Double
    public let forced: Bool

    public init(activityId: Int64, interval: Interval, submitTs: Double, forced: Bool) {
        self.activityId = activityId
        self.interval = interval
        self.submitTs = submitTs
        self.forced = forced
    }
}

/// A non-overlapping ai claim after submit-priority resolution.
public struct ResolvedAiClaim: Sendable, Equatable {
    public let activityId: Int64
    public let interval: Interval

    public init(activityId: Int64, interval: Interval) {
        self.activityId = activityId
        self.interval = interval
    }
}

/// AI submit-anchored attribution (docs/04 §B). Per-activity windows
/// `[activity_open | ai_stop, ai_submit]` (open tails dropped), plus
/// `force_owner` windows `[force_owner, next submit | force_owner | close]`.
/// Cross-activity overlaps resolve by submit-priority (earlier submit wins;
/// forced windows win outright).
public enum AiSubmitStrategy {
    /// The closed human-work windows for one activity. A left bound
    /// (`activity_open` for the first turn, or any `ai_stop`) opens a window
    /// closed by the next `ai_submit`; a left bound with no following submit
    /// is an open tail and is dropped.
    public static func windows(activityId: Int64, events: [Event], rangeEnd: Double) -> [AiWindow] {
        let sorted = events.sorted { $0.ts < $1.ts }
        let submits = sorted.filter { $0.kind == .aiSubmit }.map(\.ts)

        func nextSubmit(after t: Double) -> Double? { submits.first { $0 > t } }

        var result: [AiWindow] = []
        for event in sorted {
            switch event.kind {
            case .activityOpen, .aiStop:
                if let submit = nextSubmit(after: event.ts) {
                    result.append(AiWindow(activityId: activityId, interval: Interval(start: event.ts, end: submit), submitTs: submit, forced: false))
                }
            default:
                break
            }
        }

        // force_owner windows: bound by the next submit / force_owner / close, else range end.
        let bounds = sorted.filter { $0.kind == .aiSubmit || $0.kind == .forceOwner || $0.kind == .activityClose }.map(\.ts)
        for event in sorted where event.kind == .forceOwner {
            let end = bounds.first { $0 > event.ts } ?? rangeEnd
            if end > event.ts {
                result.append(AiWindow(activityId: activityId, interval: Interval(start: event.ts, end: end), submitTs: event.ts, forced: true))
            }
        }
        return result
    }

    /// Resolve ai-vs-ai overlaps by submit-priority: earlier submit (and any
    /// `force_owner`) owns the overlap; later windows are trimmed. Returns
    /// non-overlapping claims (one activity may yield several).
    public static func resolve(_ windows: [AiWindow]) -> [ResolvedAiClaim] {
        let ordered = windows.sorted { lhs, rhs in
            if lhs.forced != rhs.forced { return lhs.forced }             // forced first
            let lk = lhs.forced ? lhs.interval.start : lhs.submitTs
            let rk = rhs.forced ? rhs.interval.start : rhs.submitTs
            return lk < rk
        }

        var claimed: [Interval] = []
        var claims: [ResolvedAiClaim] = []
        for window in ordered {
            for piece in Interval.subtract(window.interval, claimed) {
                claims.append(ResolvedAiClaim(activityId: window.activityId, interval: piece))
            }
            claimed.append(window.interval)
        }
        return claims
    }
}
