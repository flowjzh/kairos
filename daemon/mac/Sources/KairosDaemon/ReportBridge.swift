import Foundation
import KairosCore
import KairosStore
import KairosRPC
import CKairosFFI

/// In-process reducer bridge for the Dashboard. The dashboard window lives in the
/// daemon process, so these are direct `Store` reads — not socket round-trips.
///
/// Attribution for a range is expensive (it folds the range's whole event stream)
/// and is the shared prerequisite of the chart, the summary tree, and the raw
/// rows. So it is computed **once per range** and memoized (single entry), keyed
/// by `(from, to, grace, events-watermark)`: the two open-time calls (overview,
/// then page 0) and any tab1 page flip reuse one attribution pass — and the
/// packed buffer + activities JSON are cached alongside, so a page flip does no
/// FFI prep, just a slice. A new event or a grace change bumps the key and
/// recomputes — the only two things that alter attribution for a fixed range.
///
/// The volume side (segments) crosses to Rust (`ffi/`) as a packed little-endian
/// buffer; the bounded, string-heavy side (activities) as JSON; results return as
/// JSON. See `Sources/CKairosFFI/include/KairosFFI.h` for the buffer layout.
actor ReportBridge {
    private let store: Store
    init(store: Store) { self.store = store }

    private struct Key: Equatable {
        let from: Double
        let to: Double
        let grace: Double
        let watermark: Int64
    }
    private var cachedKey: Key?
    private var cached: AttributedSegments?
    private var cachedBuffer: [UInt8]?
    private var cachedJSON: String?

    /// Timeline + summary tree + totals for `[from, to]`.
    func overview(from: Double, to: Double) async -> String? {
        guard let (seg, buffer, json) = await resolved(from: from, to: to) else { return nil }
        return reduce(seg, buffer, json) { kairos_report_overview($0, $1, $2, from, to) }
    }

    /// One page of raw rows (newest first) + the full count.
    func segments(from: Double, to: Double, offset: Int, limit: Int) async -> String? {
        guard let (seg, buffer, json) = await resolved(from: from, to: to) else { return nil }
        return reduce(seg, buffer, json) { kairos_report_segments($0, $1, $2, offset, limit) }
    }

    /// Resolve (and memoize) the attributed segments + the FFI-ready buffer and
    /// activities JSON for `[from, to]`. The buffer/JSON derive from the segments,
    /// so they share the cache key and are reused across overview + every page.
    private func resolved(from: Double, to: Double) async -> (AttributedSegments, [UInt8], String)? {
        let key = Key(from: from, to: to, grace: AppSettings.grace, watermark: (try? await store.eventsWatermark()) ?? -1)
        if key == cachedKey, let cached, let buffer = cachedBuffer, let json = cachedJSON {
            return (cached, buffer, json)
        }
        guard let seg = try? await store.attributedSegments(from: from, to: to),
              let json = activitiesJSON(seg.activities) else { return nil }
        let buffer = pack(seg.segments)
        cachedKey = key
        cached = seg
        cachedBuffer = buffer
        cachedJSON = json
        return (seg, buffer, json)
    }

    // MARK: FFI marshaling

    private func reduce(
        _ seg: AttributedSegments,
        _ buffer: [UInt8],
        _ json: String,
        _ call: (UnsafePointer<UInt8>?, Int, UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>?
    ) -> String? {
        buffer.withUnsafeBufferPointer { bp in
            json.withCString { cjson -> String? in
                guard let ptr = call(bp.baseAddress, seg.segments.count, cjson) else { return nil }
                defer { kairos_string_free(ptr) }
                return String(cString: ptr)
            }
        }
    }

    /// Pack each segment into a 32-byte little-endian record:
    /// `[i64 activity_id][f64 start][f64 end][f64 seconds]`.
    private func pack(_ segments: [Segment]) -> [UInt8] {
        var buf = [UInt8]()
        buf.reserveCapacity(segments.count * 32)
        for s in segments {
            appendLE(s.activityId, to: &buf)
            appendLE(s.start.bitPattern, to: &buf)
            appendLE(s.end.bitPattern, to: &buf)
            appendLE(s.seconds.bitPattern, to: &buf)
        }
        return buf
    }

    private func appendLE<T: FixedWidthInteger>(_ x: T, to buf: inout [UInt8]) {
        withUnsafeBytes(of: x.littleEndian) { buf.append(contentsOf: $0) }
    }

    /// The activities map as JSON (snake_case keys, matching the Rust `Activity`
    /// field names).
    private struct ActivityJSON: Encodable {
        let source: String
        let display_name: String
        let project: String?
        let title: String?
        let client_id: Int64?
        let client_name: String?
        let billable: Bool
    }

    private func activitiesJSON(_ activities: [Int64: ActivityDetail]) -> String? {
        // String keys — JSON object keys must be strings, so an Int64-keyed map is
        // keyed by stringified ids here; `decode_inputs` parses them back to i64.
        let map = Dictionary(uniqueKeysWithValues: activities.map { (id, d) in
            (String(id), ActivityJSON(
                source: d.record.source,
                display_name: d.record.displayName,
                project: d.record.project,
                title: d.record.title,
                client_id: d.client.clientId,
                client_name: d.clientName,
                billable: d.client.billable))
        })
        guard let data = try? Wire.data(map) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
