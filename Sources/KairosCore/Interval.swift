import Foundation

/// A half-open-ish time interval [start, end) used for attribution math.
public struct Interval: Sendable, Equatable {
    public let start: Double
    public let end: Double

    public init(start: Double, end: Double) {
        precondition(start <= end, "interval start must be <= end")
        self.start = start
        self.end = end
    }

    public var length: Double { end - start }

    /// Is `inner` fully contained in `self` (inner ⊆ self)? Underlies the
    /// holing rule's concurrent exception (docs/04): a lower interval fully
    /// inside a higher one is kept, not holed.
    public func contains(_ inner: Interval) -> Bool {
        start <= inner.start && inner.end <= end
    }

    /// Subtract `holes` from `window`, returning the surviving pieces
    /// (sorted, non-overlapping, non-empty). This is the holing primitive.
    public static func subtract(_ window: Interval, _ holes: [Interval]) -> [Interval] {
        let clipped = holes.compactMap { hole -> Interval? in
            let s = max(hole.start, window.start)
            let e = min(hole.end, window.end)
            return s < e ? Interval(start: s, end: e) : nil
        }.sorted { $0.start < $1.start }

        var merged: [Interval] = []
        for hole in clipped {
            if let last = merged.last, last.end >= hole.start {
                merged[merged.count - 1] = Interval(start: last.start, end: max(last.end, hole.end))
            } else {
                merged.append(hole)
            }
        }

        var result: [Interval] = []
        var cursor = window.start
        for hole in merged {
            if hole.start > cursor {
                result.append(Interval(start: cursor, end: hole.start))
            }
            cursor = max(cursor, hole.end)
        }
        if cursor < window.end {
            result.append(Interval(start: cursor, end: window.end))
        }
        return result
    }
}
