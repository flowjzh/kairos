import Foundation

/// An activity's lifecycle/visibility state (M4p3). **Storage is the `Int`
/// rawValue** (`activities.state INTEGER`); `slug` is the wire/display form.
/// Orthogonal to focus and to timing — it drives only menu visibility
/// (`active` = live switch list; `stopped` = *Start Activity* list, manual
/// only; `archived` = hidden), and attribution never reads it (docs/03, ADR 29).
public enum ActivityState: Int, Sendable, Equatable, CaseIterable {
    case active = 0
    case stopped = 1
    case archived = 2

    public var slug: String {
        switch self {
        case .active: return "active"
        case .stopped: return "stopped"
        case .archived: return "archived"
        }
    }

    public init?(slug: String) {
        guard let state = Self.allCases.first(where: { $0.slug == slug }) else { return nil }
        self = state
    }
}
