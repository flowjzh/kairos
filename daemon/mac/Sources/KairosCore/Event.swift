import Foundation

/// A row from the append-only `events` table — the sole input to attribution.
/// `payload` is opaque JSON bytes; attribution ignores it (client resolution
/// and afk reasons are handled elsewhere). `sourceId`/`payload` default for
/// test ergonomics; the store always supplies real values.
public struct Event: Sendable, Equatable {
    public let id: Int64
    public let ts: Double
    public let activityId: Int64?
    public let sourceId: Int64
    public let kind: EventKind
    public let payload: Data?

    public init(id: Int64, ts: Double, activityId: Int64?, kind: EventKind, sourceId: Int64 = 0, payload: Data? = nil) {
        self.id = id
        self.ts = ts
        self.activityId = activityId
        self.kind = kind
        self.sourceId = sourceId
        self.payload = payload
    }
}
