import Foundation

/// Maps an `attribution_version` (the code version, docs/03 / ADR 5) to the
/// attribution implementation that produced it. Watermarks capture the data
/// version; this captures the logic, so a snapshot (M3) reproduces byte-for-byte
/// even after the strategy evolves. M2 ships a single version; historical
/// implementations are added here as new cases when the logic changes.
public enum StrategyRegistry {
    public typealias Computer = @Sendable (_ events: [Event], _ from: Double, _ to: Double) -> [Segment]

    /// The version stamped into new snapshots.
    public static let currentVersion = "m2.v1"

    /// The computer for a given version, or nil if unknown (drifted / retired).
    public static func computer(version: String) -> Computer? {
        switch version {
        case currentVersion: return { Attribution.compute(events: $0, from: $1, to: $2) }
        default: return nil
        }
    }
}
