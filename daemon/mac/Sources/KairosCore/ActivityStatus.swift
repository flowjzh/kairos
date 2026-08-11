import Foundation

/// The menu green-dot / statusline state of one activity — the three states that
/// read off the focus pointer and the blur-grace window. Distinct from
/// `ActivityState`, which is stored *visibility* (`visible`/`archived`) and never
/// timing. This type carries no color/label: those are presentation, mapped by
/// each consumer (the menu dot → `Color`, the statusline → a color key string),
/// so KairosCore stays free of rendering vocabulary.
public enum ActivityStatus: Sendable, Equatable {
    case focused, gracing, idle

    /// Classify one activity at `now`. Pure and self-correcting on time: the
    /// gracing window is re-checked against `now` (a stale `pending` whose grace
    /// has elapsed resolves to `.idle` here), so a caller that cached `pending`
    /// at an earlier instant still gets the right answer without a recompute.
    /// `grace` is the blur-grace seconds (`AppSettings.grace`); a non-positive
    /// grace never qualifies (matches `Grace.pending`'s `to - t <= grace` gate).
    public static func derive(
        focused: Int64?,
        pending: Grace.Pending?,
        id: Int64,
        now: Double,
        grace: Double
    ) -> ActivityStatus {
        if focused == id { return .focused }
        if let pending, pending.activityId == id, grace > 0, now - pending.blurTs <= grace {
            return .gracing
        }
        return .idle
    }
}
