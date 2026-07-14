import Foundation

/// A computed attributed-time block. Client/project are not on the segment —
/// they are resolved from the referenced activity at read time (see docs/03).
public struct Segment: Sendable, Equatable, Codable {
    public let activityId: Int64
    public let start: Double
    public let end: Double
    public let seconds: Double
    public let rule: String

    public init(activityId: Int64, start: Double, end: Double, seconds: Double, rule: String) {
        self.activityId = activityId
        self.start = start
        self.end = end
        self.seconds = seconds
        self.rule = rule
    }
}
