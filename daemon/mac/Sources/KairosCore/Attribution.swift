import Foundation

/// The pure, read-time attribution entry point (docs/04). Events + range →
/// segments, computed in memory, nothing written back.
///
/// Since M4p3 there is **one focus-driven model**, no per-source strategy: the
/// base of an activity's time is the union of intervals where it held the single
/// focus pointer (`focus`/`blur` reduction), from which we subtract that
/// activity's own AI grind (`[ai_submit, ai_stop]`) and the global afk and pause
/// spans. One activity is focused at a time, so `sum(seconds) ≤ wall-clock`.
public enum Attribution {
    public static func compute(events: [Event], from: Double, to: Double) -> [Segment] {
        let globals = GlobalState.reduce(events: events, to: to)
        let submits = events.compactMap { $0.kind == .aiSubmit ? $0.ts : nil }
        // An `ai_submit` inside an afk span is evidence of presence: break the
        // span there (covers an offline gap the user actually submitted into).
        let globalHoles = breakAfk(globals.afk, submits: submits) + globals.pause

        var byActivity: [Int64: [Event]] = [:]
        for event in events where event.activityId != nil {
            byActivity[event.activityId!, default: []].append(event)
        }

        var segments: [Segment] = []
        for (activityId, focusIntervals) in focusIntervals(events: events, to: to) {
            let holes = aiWorking(events: byActivity[activityId] ?? [], to: to) + globalHoles
            for interval in focusIntervals {
                let start = max(interval.start, from)
                let end = min(interval.end, to)
                guard start < end else { continue }
                for piece in Interval.subtract(Interval(start: start, end: end), holes) {
                    segments.append(Segment(
                        activityId: activityId, start: piece.start, end: piece.end,
                        seconds: piece.length, rule: "focus"))
                }
            }
        }
        return segments
    }

    /// Reduce `focus`/`blur` into per-activity intervals where that activity held
    /// the single pointer. Latest `focus` wins; a `blur` closes only the current
    /// holder; a still-focused tail extends to `to`.
    static func focusIntervals(events: [Event], to: Double) -> [Int64: [Interval]] {
        var result: [Int64: [Interval]] = [:]
        var current: Int64?
        var openStart = 0.0

        func close(at ts: Double) {
            if let c = current, ts > openStart {
                result[c, default: []].append(Interval(start: openStart, end: ts))
            }
        }

        for event in events.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            switch event.kind {
            case .focus:
                if current != event.activityId {
                    close(at: event.ts)
                    current = event.activityId
                    openStart = event.ts
                }
            case .blur:
                if current == event.activityId {
                    close(at: event.ts)
                    current = nil
                }
            default:
                break
            }
        }
        if current != nil { close(at: to) }
        return result
    }

    /// The activity's AI-grind spans `[ai_submit, ai_stop]` to subtract. A submit
    /// with no following stop (agent still running) extends to `to`; repeated
    /// submits before a stop keep the earliest start (the machine was busy
    /// throughout). Reading after an `ai_stop` (no next submit) is NOT a grind —
    /// it survives, so the old tail-loss is fixed.
    static func aiWorking(events: [Event], to: Double) -> [Interval] {
        var spans: [Interval] = []
        var grindStart: Double?
        for event in events.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            switch event.kind {
            case .aiSubmit:
                if grindStart == nil { grindStart = event.ts }
            case .aiStop:
                if let start = grindStart {
                    if event.ts > start { spans.append(Interval(start: start, end: event.ts)) }
                    grindStart = nil
                }
            default:
                break
            }
        }
        if let start = grindStart, to > start { spans.append(Interval(start: start, end: to)) }
        return spans
    }

    /// Truncate each afk span to end at the earliest submit strictly inside it
    /// (docs/04) — the submit proves you were active at that instant.
    private static func breakAfk(_ afk: [Interval], submits: [Double]) -> [Interval] {
        afk.map { span in
            guard let s = submits.filter({ $0 > span.start && $0 < span.end }).min() else { return span }
            return Interval(start: span.start, end: s)
        }
    }
}
