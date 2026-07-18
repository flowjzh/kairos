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

/// Menu placement, fully derived from the focus/blur log (ADR 37). `state` is a
/// visibility flag only, so the single visible list is split into the three
/// sections by each activity's timeline. "Ended" is a manual-only notion: a
/// manual's blur is its end (scheduled `blur@end` or the ✕-now blur); an auto
/// activity's blurs are transient, so it stays Ongoing while visible (an exited
/// auto is `archived`, never in this list).
public enum ActivityBuckets {
    /// Split the visible activities into Ongoing / Upcoming / Recent.
    /// - manual + earliest focus ahead → upcoming
    /// - manual + last timing event a past blur (no focus after it) → recent
    /// - else → ongoing (manual backdrop/ongoing, or any visible auto)
    /// Upcoming is sorted by start; recent by last focus time.
    public static func partition(
        visible: [ActivityRecord],
        events: [Event],
        now: Double
    ) -> (ongoing: [ActivityRecord], upcoming: [ScheduledActivity], recent: [ActivityRecord]) {
        let earliestFocus = Self.earliestFocus(events: events)
        let lastBlur = Self.lastBlur(events: events)
        let lastFocus = Self.lastFocus(events: events)
        var ongoing: [ActivityRecord] = []
        var upcoming: [ScheduledActivity] = []
        var recent: [ActivityRecord] = []
        for a in visible {
            if a.manual, let start = earliestFocus[a.id], start > now {
                upcoming.append(ScheduledActivity(record: a, start: start))
            } else if a.manual, Self.isEnded(a.id, lastBlur: lastBlur, lastFocus: lastFocus, now: now) {
                recent.append(a)
            } else {
                ongoing.append(a)
            }
        }
        let byLastFocus = recent.sorted { (lastFocus[$0.id] ?? 0) > (lastFocus[$1.id] ?? 0) }
        return (ongoing, upcoming.sorted { $0.start < $1.start }, byLastFocus)
    }

    /// Earliest `focus` ts per activity (a manual's start).
    static func earliestFocus(events: [Event]) -> [Int64: Double] {
        extreme(events: events, kind: .focus, min: true)
    }

    /// Latest `blur` ts per activity (a manual's end).
    static func lastBlur(events: [Event]) -> [Int64: Double] {
        extreme(events: events, kind: .blur, min: false)
    }

    /// Latest `focus` ts per activity (for ordering Recent + auto-catch's
    /// most-recently-focused pick).
    static func lastFocus(events: [Event]) -> [Int64: Double] {
        extreme(events: events, kind: .focus, min: false)
    }

    /// A manual is ended (Recent) if its last timing event is a past blur —
    /// started, blurred, and not re-focused since. One definition shared by
    /// `partition` and the backdrop auto-catch filter, so the menu and the
    /// catch agree on what's still an ongoing backdrop.
    static func isEnded(_ id: Int64, lastBlur: [Int64: Double], lastFocus: [Int64: Double], now: Double) -> Bool {
        guard let end = lastBlur[id], end <= now else { return false }
        return end >= (lastFocus[id] ?? -.infinity)
    }

    /// Per-activity extreme `ts` of events of `kind` — the one fold behind
    /// earliest-focus / last-blur / last-focus.
    private static func extreme(events: [Event], kind: EventKind, min: Bool) -> [Int64: Double] {
        var out: [Int64: Double] = [:]
        for e in events where e.kind == kind {
            guard let a = e.activityId else { continue }
            out[a] = out[a].map { minw($0, e.ts, min: min) } ?? e.ts
        }
        return out
    }
}

/// `min` ? lesser : greater — pick the extreme, defaulting the seed accordingly.
private func minw(_ a: Double, _ b: Double, min: Bool) -> Double {
    min ? Swift.min(a, b) : Swift.max(a, b)
}
