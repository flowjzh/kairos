import Foundation

/// Predicts the current owner activity: the latest claim (`activity_open` /
/// `ai_stop` / `force_owner`) whose activity has no later `activity_close`.
/// afk, pause, and `ai_submit` do NOT clear it — they are temporary states
/// surfaced separately (the menu shows "Idle"/"Paused"), and owner.get still
/// returns the active activity. A thin reader over `GlobalState` (ADR 21).
public enum OwnerPredictor {
    public static func predict(events: [Event]) -> Int64? {
        // Owner is independent of the range; use an upper bound that can't
        // produce a negative-length open span in the reducer.
        GlobalState.reduce(events: events, to: .greatestFiniteMagnitude).owner
    }
}
