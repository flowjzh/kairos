import Foundation

/// Blur-grace for auto activities. A short blur — switching to an untracked app
/// (a browser) to check something — shouldn't chop an auto activity into
/// segments: when an auto activity blurs to void (nothing else focused) and is
/// re-focused within `seconds`, the blur is absorbed (the span stays focus);
/// otherwise it stands. The excursion then reads as one continuous stretch
/// instead of two segments split by the brief leave.
///
/// **Manual activities never get grace.** A manual's blur is an intentional stop
/// (✕ / scheduled end / archive), and `autoCatch` is itself gated on `!manual`,
/// so a manual blur to void is never a "brief excursion" — absorbing it would
/// erase a deliberate boundary (e.g. a meeting's scheduled end). The gate
/// mirrors `Store.isActivityManual` via the `manualIds` set passed in.
///
/// Pure read-time: the blur is always persisted; absorption is a derivation over
/// the event log, applied identically by billing (`Attribution`) and the live
/// menu, so the two cannot drift. `GlobalState.reduce` (the raw pointer) is
/// untouched — `autoCatch` and the idle sampler keep reading the un-absorbed log.
public enum Grace {
    /// Blur event ids to absorb: an auto activity's blur where the next focus
    /// within `grace` returns to that same activity (no other focus between).
    /// Callers drop these ids before reducing, so the focus pointer and
    /// intervals see one continuous span. Manual blurs are never absorbed.
    public static func absorbedBlurIds(events: [Event], grace: Double, manualIds: Set<Int64>) -> Set<Int64> {
        let sorted = events.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
        var current: Int64?
        var absorbed = Set<Int64>()
        for (i, e) in sorted.enumerated() {
            switch e.kind {
            case .focus:
                current = e.activityId
            case .blur:
                guard let a = e.activityId, current == a else { continue }  // no-op unless it clears the holder
                if manualIds.contains(a) { current = nil; continue }        // manual blurs always stand
                // Peek for the deciding focus within grace; the first focus
                // settles it (to `a` → absorb, to anything else → keep the blur).
                var absorb = false
                var j = i + 1
                while j < sorted.count, sorted[j].ts <= e.ts + grace {
                    if sorted[j].kind == .focus {
                        absorb = sorted[j].activityId == a
                        break
                    }
                    j += 1
                }
                if absorb { absorbed.insert(e.id) } else { current = nil }
            default:
                break
            }
        }
        return absorbed
    }

    /// Events with grace-absorbable blurs removed — the view the menu and billing
    /// reduce over (pointer, placement, segments) so focus/billing can't drift.
    /// Manuals never get grace. A pure pre-derivation transform (ADR 39);
    /// `autoCatch` and the idle sampler still read the raw, un-absorbed log.
    public static func absorbedView(events: [Event], grace: Double, manualIds: Set<Int64>) -> [Event] {
        let absorbed = absorbedBlurIds(events: events, grace: grace, manualIds: manualIds)
        return absorbed.isEmpty ? events : events.filter { !absorbed.contains($0.id) }
    }

    /// The auto activity in its blur-grace window at `to` — the most recent blur
    /// to void is within `grace` and no focus has followed — else nil. This is
    /// the live-edge case (the blur is not yet absorbed because no re-focus has
    /// arrived); the menu shows it as a tentative, light-green focus. Manuals
    /// never qualify. Run on the same absorbed view as `GlobalState.reduce`.
    public static func pending(events: [Event], to: Double, grace: Double, manualIds: Set<Int64>) -> Pending? {
        let sorted = events.filter { $0.ts <= to }.sorted { ($0.ts, $0.id) < ($1.ts, $1.id) }
        var current: Int64?
        var lastClearActivity: Int64?
        var lastClearTs: Double?
        for e in sorted {
            switch e.kind {
            case .focus:
                current = e.activityId
            case .blur:
                guard let a = e.activityId, current == a else { continue }
                lastClearActivity = a
                lastClearTs = e.ts
                current = nil
            default:
                break
            }
        }
        guard current == nil,                                           // nobody focused
              let a = lastClearActivity, !manualIds.contains(a),        // auto only
              let t = lastClearTs, to - t <= grace else { return nil }
        return Pending(activityId: a, blurTs: t)
    }

    /// A live grace state: which auto activity is tentatively focused, and when
    /// its blur happened (expiry = `blurTs + grace`).
    public struct Pending: Sendable, Equatable {
        public let activityId: Int64
        public let blurTs: Double

        public init(activityId: Int64, blurTs: Double) {
            self.activityId = activityId
            self.blurTs = blurTs
        }
    }
}
