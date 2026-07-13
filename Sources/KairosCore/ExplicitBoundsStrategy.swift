import Foundation

/// Explicit-bounds attribution (docs/04 §A): a window `[activity_open,
/// activity_close]`, holed only by `pause` (immune to afk and ai). The
/// default strategy for meetings, manual tasks, and any client that knows
/// its own start/stop. M2 adds the ai submit-anchored strategy + signature
/// dispatch; until then every activity uses this.
public struct ExplicitBoundsStrategy: Sendable {
    public static func segments(activityId: Int64, events: [Event], globals: GlobalSpans, from: Double, to: Double) -> [Segment] {
        let sorted = events.sorted { $0.ts < $1.ts }
        guard let open = sorted.first(where: { $0.kind == .activityOpen }) else { return [] }
        let close = sorted.first(where: { $0.kind == .activityClose && $0.ts > open.ts })

        let windowStart = max(open.ts, from)
        let windowEnd = min(close?.ts ?? to, to)
        guard windowStart < windowEnd else { return [] }

        let window = Interval(start: windowStart, end: windowEnd)
        return Interval.subtract(window, globals.pause).map { piece in
            Segment(activityId: activityId, start: piece.start, end: piece.end, seconds: piece.length, rule: "explicit")
        }
    }
}
