import Foundation

/// The single reduction over the event log (ADR 21). One pass yields the afk and
/// pause spans and the **focused** activity — the derivations the menu and the
/// attribution deductions read. Since M4p3 the focus pointer replaces the old
/// "owner": `focus` moves it (latest wins), `blur` clears it *only if it targets
/// the current holder* (so a stale/out-of-order blur is a no-op). A focus/blur
/// dated after `to` is ignored — the pointer reflects state *as of* `to`, so a
/// meeting scheduled for a future start lights up only when its time arrives.
/// afk and pause are independent spans and do not change the focused activity.
///
/// Only the focus pointer is derived here; the visible-activity *set* and its
/// placement (Ongoing/Upcoming/Recent) are derived separately by `ActivityBuckets`
/// (ADR 37). `activities.state` is a visibility flag (visible/archived), never
/// timing; attribution never reads it (ADR 29).
public struct GlobalState: Sendable, Equatable {
    public let afk: [Interval]
    public let pause: [Interval]
    public let focused: Int64?
    public let isAfk: Bool
    public let isPaused: Bool

    public static func reduce(events: [Event], to: Double) -> GlobalState {
        var afk: [Interval] = []
        var pause: [Interval] = []
        var afkStart: Double?
        var pauseStart: Double?
        var focused: Int64?

        for event in events.sorted(by: { ($0.ts, $0.id) < ($1.ts, $1.id) }) {
            switch event.kind {
            case .afkOn:
                if afkStart == nil { afkStart = event.ts }
            case .afkOff:
                if let start = afkStart { afk.append(Interval(start: start, end: event.ts)); afkStart = nil }
            case .pauseOn:
                if pauseStart == nil { pauseStart = event.ts }
            case .pauseOff:
                if let start = pauseStart { pause.append(Interval(start: start, end: event.ts)); pauseStart = nil }
            case .focus:
                // Ignore a focus scheduled after `to` (e.g. a meeting created with
                // a future start): the pointer lights only once its time arrives.
                if event.ts <= to { focused = event.activityId }
            case .blur:
                if event.ts <= to, focused == event.activityId { focused = nil }
            default:
                break
            }
        }
        if let start = afkStart { afk.append(Interval(start: start, end: to)) }
        if let start = pauseStart { pause.append(Interval(start: start, end: to)) }

        return GlobalState(
            afk: afk, pause: pause, focused: focused,
            isAfk: afkStart != nil, isPaused: pauseStart != nil)
    }
}
