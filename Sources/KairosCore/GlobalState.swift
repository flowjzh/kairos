import Foundation

/// The single reduction over the event log (ADR 21). One pass yields the afk
/// and pause spans, the current owner, and the set of open activities — the
/// three derivations that previously lived in `GlobalSpans`, `OwnerPredictor`,
/// and the menu model independently and could drift apart. Those now read from
/// here.
///
/// Owner: `activity_open` / `ai_stop` / `force_owner` claim; `activity_close`
/// releases. afk / pause / `ai_submit` are surfaced separately and do NOT
/// change the owner (docs/06 §6). afk and pause are independent spans, so both
/// can be open at once without either masking the other.
public struct GlobalState: Sendable, Equatable {
    public let afk: [Interval]
    public let pause: [Interval]
    public let owner: Int64?
    public let openActivities: [Int64]
    public let isAfk: Bool
    public let isPaused: Bool

    public static func reduce(events: [Event], to: Double) -> GlobalState {
        var afk: [Interval] = []
        var pause: [Interval] = []
        var afkStart: Double?
        var pauseStart: Double?
        var open: [Int64] = []
        // Claimant activity ids, latest last. Owner is the last claim whose
        // activity is still open (docs/06 §6): a close removes only that
        // activity's claim, so ownership reverts to the prior still-open claim.
        var claims: [Int64] = []

        func claim(_ id: Int64?) {
            guard let id else { return }
            claims.removeAll { $0 == id }
            claims.append(id)
        }

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
            case .activityOpen:
                if let id = event.activityId, !open.contains(id) { open.append(id) }
                claim(event.activityId)
            case .aiStop, .forceOwner:
                claim(event.activityId)
            case .activityClose:
                if let id = event.activityId {
                    open.removeAll { $0 == id }
                    claims.removeAll { $0 == id }
                }
            default:
                break
            }
        }
        if let start = afkStart { afk.append(Interval(start: start, end: to)) }
        if let start = pauseStart { pause.append(Interval(start: start, end: to)) }

        return GlobalState(
            afk: afk, pause: pause, owner: claims.last, openActivities: open,
            isAfk: afkStart != nil, isPaused: pauseStart != nil)
    }
}
