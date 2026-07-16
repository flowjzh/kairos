import Foundation

/// A row from the append-only `events` table — the sole input to attribution.
/// `activityId` is the owner: non-nil = the activity's own event; nil = a global
/// daemon event (afk/pause). `payload` is opaque JSON bytes attribution ignores;
/// it defaults for test ergonomics. Ownership model + why the event carries no
/// source: ADR 38.
public struct Event: Sendable, Equatable {
    public let id: Int64
    public let ts: Double
    public let activityId: Int64?
    public let kind: EventKind
    public let payload: Data?

    public init(id: Int64, ts: Double, activityId: Int64?, kind: EventKind, payload: Data? = nil) {
        self.id = id
        self.ts = ts
        self.activityId = activityId
        self.kind = kind
        self.payload = payload
    }
}
