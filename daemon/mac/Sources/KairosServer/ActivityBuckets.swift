import Foundation
import KairosCore
import KairosStore

/// A manual activity scheduled to start in the future (its `focus` is dated
/// after now) — the menu's "Upcoming" rows.
public struct ScheduledActivity: Identifiable, Sendable, Equatable {
    public let record: ActivityRecord
    public let start: Double
    public var id: Int64 { record.id }

    public init(record: ActivityRecord, start: Double) {
        self.record = record
        self.start = start
    }
}

/// Time-derived menu placement, independent of the mutable `state` column: a
/// manual activity's `focus`/`blur` timeline decides whether it is upcoming
/// (start ahead), active (running), or recent (ended). This is why a timed
/// meeting — stored `stopped` at creation with a future `blur@end` — still lands
/// in the right section instead of always in Recent.
public enum ActivityBuckets {
    /// Partition the two store lists into the three menu sections. `active` are
    /// the live (`state=active`) rows; `stopped` are the stopped manual rows
    /// (incl. timed meetings). `events` supplies each activity's focus/blur
    /// times; `now` is the clock. Upcoming is returned sorted by start.
    public static func partition(
        active: [ActivityRecord],
        stopped: [ActivityRecord],
        events: [Event],
        now: Double
    ) -> (active: [ActivityRecord], upcoming: [ScheduledActivity], recent: [ActivityRecord]) {
        var earliestFocus: [Int64: Double] = [:]
        var lastBlur: [Int64: Double] = [:]
        for e in events {
            guard let a = e.activityId else { continue }
            if e.kind == .focus { earliestFocus[a] = min(earliestFocus[a] ?? .infinity, e.ts) }
            else if e.kind == .blur { lastBlur[a] = max(lastBlur[a] ?? -.infinity, e.ts) }
        }

        var activeOut: [ActivityRecord] = []
        var upcoming: [ScheduledActivity] = []
        var recent: [ActivityRecord] = []

        // Live rows: an unstarted manual one is upcoming, else active. A blur here
        // only means "not currently focused", never "ended".
        for a in active {
            if a.manual, let start = earliestFocus[a.id], start > now {
                upcoming.append(ScheduledActivity(record: a, start: start))
            } else {
                activeOut.append(a)
            }
        }
        // Stopped manual rows: future start → upcoming, still-running (end ahead)
        // → active, concluded (last blur in the past) → recent.
        for a in stopped {
            if let start = earliestFocus[a.id], start > now {
                upcoming.append(ScheduledActivity(record: a, start: start))
            } else if let end = lastBlur[a.id], end > now {
                activeOut.append(a)
            } else {
                recent.append(a)
            }
        }

        return (activeOut, upcoming.sorted { $0.start < $1.start }, recent)
    }
}
