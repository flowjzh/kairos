import Foundation

/// Event kinds. **Storage is the `Int` rawValue** (compact `events.kind INTEGER`);
/// the **wire/CLI form is `slug`** (language-neutral JSON, e.g. `"ai_submit"`) —
/// the same split as sources/projects (wire slug ↔ stored id). A closed set, so
/// it is a code enum, not a lookup table. Values are stable and must never be
/// reordered (M4p3 removed `activity_open`/`activity_close`/`force_owner`).
public enum EventKind: Int, Sendable, Equatable, CaseIterable {
    case aiStop = 1
    case aiSubmit = 2
    case focus = 3
    case blur = 4
    case afkOn = 5
    case afkOff = 6
    case pauseOn = 7
    case pauseOff = 8
    case activityOverride = 9

    /// The wire/CLI slug (single source of truth for the string form).
    public var slug: String {
        switch self {
        case .aiStop: return "ai_stop"
        case .aiSubmit: return "ai_submit"
        case .focus: return "focus"
        case .blur: return "blur"
        case .afkOn: return "afk_on"
        case .afkOff: return "afk_off"
        case .pauseOn: return "pause_on"
        case .pauseOff: return "pause_off"
        case .activityOverride: return "activity_override"
        }
    }

    /// Parse the wire slug (used at the RPC boundary).
    public init?(slug: String) {
        guard let kind = Self.allCases.first(where: { $0.slug == slug }) else { return nil }
        self = kind
    }
}
