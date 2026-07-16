import Foundation

/// An activity's visibility (`activities.state INTEGER`); `slug` is the
/// wire/display form. **Visibility only** — placement (Ongoing / Upcoming /
/// Recent) is derived live from the focus/blur event log, not stored here (ADR
/// 37). `visible` rows appear in a menu section (which one is derived);
/// `archived` rows are hidden from every list. Attribution never reads it
/// (docs/03, ADR 29).
public enum ActivityState: Int, Sendable, Equatable, CaseIterable {
    case visible = 0
    case archived = 1

    public var slug: String {
        switch self {
        case .visible: return "visible"
        case .archived: return "archived"
        }
    }

    public init?(slug: String) {
        guard let state = Self.allCases.first(where: { $0.slug == slug }) else { return nil }
        self = state
    }
}
