import Foundation

/// Maps an `attribution_version` (the code version, docs/03 / ADR 5) to the
/// attribution implementation that produced it. Watermarks capture the data
/// version; this captures the logic, so a snapshot (M6) reproduces byte-for-byte
/// even after the model evolves. Since M4p3 there is a single focus-driven
/// model; historical implementations are added here as new cases when it changes.
public enum StrategyRegistry {
    public typealias Computer = @Sendable (_ events: [Event], _ from: Double, _ to: Double) -> [Segment]

    /// The version stamped into new snapshots.
    public static let currentVersion = "m4p3.v1"

    /// The computer for a given version, or nil if unknown (drifted / retired).
    public static func computer(version: String) -> Computer? {
        switch version {
        case currentVersion: return { Attribution.compute(events: $0, from: $1, to: $2) }
        default: return nil
        }
    }
}
