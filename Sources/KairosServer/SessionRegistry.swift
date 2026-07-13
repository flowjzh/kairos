import Foundation

/// In-memory, self-healing map from a `kairos-pty` session (`KAIROS_SESSION_ID`)
/// to the Claude activity it wraps (`source`, `external_id`). Ephemeral by
/// design (M4): a `KAIROS_SESSION_ID` is only meaningful while its wrapper is
/// alive, so the lookup domain is exactly the active wrappers — no persistence,
/// no history search. Every hook RPC carries the id and re-registers, so a
/// daemon restart is repaired by the next hook; the only loss is focus reports
/// in the gap before it.
///
/// A focus report that arrives before the first hook (the startup race) is
/// buffered (latest wins) and flushed when the mapping registers.
public actor SessionRegistry {
    public struct Target: Sendable, Equatable {
        public let source: String
        public let externalId: String
    }

    public struct Pending: Sendable, Equatable {
        public let focused: Bool
        public let ts: Double
    }

    private var map: [String: Target] = [:]
    private var pending: [String: Pending] = [:]

    public init() {}

    /// Register (or refresh) a mapping. Returns a buffered focus report, if one
    /// arrived before the mapping existed, so the caller can flush it now.
    public func register(_ kairosSessionId: String, source: String, externalId: String) -> Pending? {
        map[kairosSessionId] = Target(source: source, externalId: externalId)
        return pending.removeValue(forKey: kairosSessionId)
    }

    public func resolve(_ kairosSessionId: String) -> Target? {
        map[kairosSessionId]
    }

    /// Hold a focus report whose mapping isn't known yet (latest wins).
    public func buffer(_ kairosSessionId: String, focused: Bool, ts: Double) {
        pending[kairosSessionId] = Pending(focused: focused, ts: ts)
    }
}
