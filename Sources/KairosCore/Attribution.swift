import Foundation

/// The pure, read-time attribution entry point (docs/04). Events + range →
/// segments, computed in memory, nothing written back. Dispatches per activity
/// by event signature: an activity with `ai_submit` events uses the ai
/// submit-anchored strategy; otherwise explicit-bounds. Cross-activity ai-vs-ai
/// (submit-priority) and the explicit-vs-ai holing rule run here, after the
/// per-activity windows are built.
public enum Attribution {
    public static func compute(events: [Event], from: Double, to: Double) -> [Segment] {
        let globals = GlobalSpans.extract(events: events, to: to)

        var byActivity: [Int64: [Event]] = [:]
        for event in events where event.activityId != nil {
            byActivity[event.activityId!, default: []].append(event)
        }

        var segments: [Segment] = []
        var explicitWindows: [Interval] = []
        var aiWindows: [AiWindow] = []
        for (activityId, activityEvents) in byActivity {
            if activityEvents.contains(where: { $0.kind == .aiSubmit }) {
                aiWindows += AiSubmitStrategy.windows(activityId: activityId, events: activityEvents, rangeEnd: to)
            } else {
                let explicit = ExplicitBoundsStrategy.segments(
                    activityId: activityId, events: activityEvents, globals: globals, from: from, to: to)
                segments += explicit
                explicitWindows += explicit.map { Interval(start: $0.start, end: $0.end) }
            }
        }

        // ai holes: afk (immune below is explicit; here ai IS holed) with the
        // submit-break, plus pause. Explicit-vs-ai holing is applied per piece.
        let submits = events.compactMap { $0.kind == .aiSubmit ? $0.ts : nil }
        let holes = breakAfk(globals.afk, submits: submits) + globals.pause

        for claim in AiSubmitStrategy.resolve(aiWindows) {
            let clipped = Interval(start: max(claim.interval.start, from), end: min(claim.interval.end, to))
            guard clipped.start < clipped.end else { continue }
            for piece in Interval.subtract(clipped, holes) {
                for surviving in holeByExplicit(piece, explicitWindows) {
                    segments.append(Segment(
                        activityId: claim.activityId, start: surviving.start, end: surviving.end,
                        seconds: surviving.length, rule: "ai"))
                }
            }
        }
        return segments
    }

    /// An `ai_submit` inside an afk span is evidence of activity: the span
    /// breaks at that instant (docs/04 step 4, docs/06). Truncate each afk span
    /// to end at the earliest submit strictly inside it.
    private static func breakAfk(_ afk: [Interval], submits: [Double]) -> [Interval] {
        afk.map { span in
            guard let s = submits.filter({ $0 > span.start && $0 < span.end }).min() else { return span }
            return Interval(start: span.start, end: s)
        }
    }

    /// Explicit-vs-ai holing rule (docs/04): if the ai piece is fully contained
    /// in some explicit window it is a genuine embedded sub-effort → keep it
    /// (concurrent); otherwise the explicit windows punch holes in it.
    private static func holeByExplicit(_ piece: Interval, _ explicit: [Interval]) -> [Interval] {
        if explicit.contains(where: { $0.contains(piece) }) { return [piece] }
        return Interval.subtract(piece, explicit)
    }
}
