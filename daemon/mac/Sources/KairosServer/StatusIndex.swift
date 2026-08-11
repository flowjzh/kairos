import Foundation
import KairosCore
import KairosStore

/// The live, memoized answer behind `activities.status`. Each statusline poll
/// (frequent: CC re-renders on every event, not just the 15 s `refreshInterval`)
/// would otherwise re-scan the **entire** event log on the serialized `Store`
/// actor — `loadEventsInRange(from: 0)` + a full `Attribution.compute`. This
/// cache collapses that to one rebuild per ingested event.
///
/// **Invalidation is watermark-keyed.** Every write bumps `eventsWatermark`, so
/// the cache rebuilds exactly when the event log changes, and serves from memory
/// between events. The calendar-day component rolls `today` at midnight. No
/// subscription and no timers: `ActivityStatus.derive(now)` resolves the
/// time-driven gracing→idle edge live, so a cached `pending` is self-correcting.
///
/// **The live tail is exact.** Derived state is constant between events (focus
/// moves, afk/pause/ai-grind flips are all events), so for the one activity that
/// is net-accumulating focus right now, `total`/`today` grow at rate 1 and:
///
///     Attribution(to = now) ≡ Attribution(to = refreshNow) + (now − refreshNow)
///
/// while every other activity holds steady. `rate` is 0 the instant an afk,
/// pause, or ai-grind hole is open, so the tail never counts non-focus time. The
/// snapshot stores the attribution closed at `refreshNow`; `query` adds the tail.
public actor StatusIndex {
    /// One activity's derived numbers at a fixed `refreshNow`.
    private struct Snapshot {
        let refreshNow: Double
        let focused: Int64?
        let pending: Grace.Pending?
        /// Is the focused activity net-accumulating focus at `refreshNow` (not
        /// afk, paused, or ai-grinding)? Drives the live-tail rate.
        let rate: Bool
        let grace: Double
        /// Settled net-focus seconds per activity, attribution closed at
        /// `refreshNow` (the open focus segment included up to `refreshNow`).
        let entries: [Int64: (total: Double, today: Double)]

        func query(_ id: Int64, now: Double) -> StatusSnapshot {
            let state = ActivityStatus.derive(focused: focused, pending: pending, id: id, now: now, grace: grace)
            let tail = (rate && focused == id) ? max(0, now - refreshNow) : 0
            let e = entries[id] ?? (0, 0)
            return StatusSnapshot(state: state, total: e.total + tail, today: e.today + tail)
        }
    }

    private struct Cache {
        let watermark: Int64
        let dayStart: Date
        let snap: Snapshot
    }

    private var cache: Cache?

    public init() {}

    /// `(state, totalSeconds, todaySeconds)` for `id`, correct as of `now`.
    /// Rebuilds only when the event watermark or the calendar day changes;
    /// otherwise serves the snapshot plus the live focus tail. One store per
    /// `StatusIndex` (production is 1:1; each owning test builds its own), so the
    /// watermark is an exact generational key — no store-identity check needed.
    public func query(store: Store, id: Int64, now: Double) async -> StatusSnapshot {
        let watermark = (try? await store.eventsWatermark()) ?? 0
        let dayStart = Self.dayStart(now)
        if let c = cache, c.watermark == watermark, c.dayStart == dayStart {
            return c.snap.query(id, now: now)
        }
        let snap = await Self.build(store: store, now: now)
        cache = Cache(watermark: watermark, dayStart: dayStart, snap: snap)
        return snap.query(id, now: now)
    }

    /// Force the next `query` to rebuild (test hook / settings change).
    public func invalidate() {
        cache = nil
    }

    /// Recompute the full per-activity snapshot from the event log. The expensive
    /// path — but it runs at most once per watermark bump, not per poll.
    private static func build(store: Store, now: Double) async -> Snapshot {
        let grace = AppSettings.grace
        let events = (try? await store.loadEventsInRange(from: 0, to: now)) ?? []
        let manualIds = (try? await store.manualActivityIds()) ?? []
        let view = Grace.absorbedView(events: events, grace: grace, manualIds: manualIds)
        let focused = GlobalState.reduce(events: view, to: now).focused
        let pending = Grace.pending(events: view, to: now, grace: grace, manualIds: manualIds)

        let midnight = Self.dayStart(now).timeIntervalSince1970
        let segments = Attribution.compute(events: events, from: 0, to: now)
        var entries: [Int64: (total: Double, today: Double)] = [:]
        for seg in segments {
            var e = entries[seg.activityId] ?? (0, 0)
            e.total += seg.seconds
            let lo = max(seg.start, midnight), hi = min(seg.end, now)
            if lo < hi { e.today += hi - lo }
            entries[seg.activityId] = e
        }
        // The focused activity is net-accumulating at `now` iff one of its
        // segments ends at `now`: the open focus interval, with no open hole
        // (afk / pause / ai-grind) covering the live edge — holes already split
        // the segments, so this reads the result straight off Attribution, with
        // no separate afk/paused/ai-submit scan.
        let rate = focused.map { id in segments.contains { $0.activityId == id && $0.end == now } } ?? false

        return Snapshot(refreshNow: now, focused: focused, pending: pending, rate: rate, grace: grace, entries: entries)
    }

    private static func dayStart(_ ts: Double) -> Date {
        Calendar.current.startOfDay(for: Date(timeIntervalSince1970: ts))
    }
}

/// The derived state + net-focus durations for one activity at an instant.
public struct StatusSnapshot: Sendable, Equatable {
    public let state: ActivityStatus
    public let total: Double
    public let today: Double

    public init(state: ActivityStatus, total: Double, today: Double) {
        self.state = state
        self.total = total
        self.today = today
    }
}
