import Foundation

/// In-memory, self-healing map from a `kairos` PTY session (`KAIROS_SESSION_ID`,
/// "kid") to the activity it drives. Ephemeral by design (M4): a kid is only
/// meaningful while its wrapper is alive, so the lookup domain is exactly the
/// active wrappers — no persistence, no history search. Every hook RPC (and the
/// wrapper's ensure-create) registers the kid, so a daemon restart is repaired by
/// the next one; the only loss is focus reports in the gap before it.
///
/// A focus report that arrives before the mapping exists (the launch race) is
/// buffered (latest wins) and flushed when the mapping registers.
public actor SessionRegistry {
    public struct Pending: Sendable, Equatable {
        public let focused: Bool
        public let ts: Double
    }

    private var map: [String: Int64] = [:]
    private var pending: [String: Pending] = [:]
    /// Activity ids started with AFK detection off — in-memory soft state (not
    /// persisted, ADR 33): while such an activity is focused the idle sampler
    /// emits no `afk`, so the log simply has no span to deduct. Resets on restart.
    private var afkImmune: Set<Int64> = []

    public init() {}

    /// Register (or refresh) kid → activity. Returns a buffered focus report, if
    /// one arrived before the mapping existed, so the caller can flush it now.
    public func register(_ kid: String, activityId: Int64) -> Pending? {
        map[kid] = activityId
        return pending.removeValue(forKey: kid)
    }

    public func resolve(_ kid: String) -> Int64? { map[kid] }

    /// Hold a focus report whose mapping isn't known yet (latest wins).
    public func buffer(_ kid: String, focused: Bool, ts: Double) {
        pending[kid] = Pending(focused: focused, ts: ts)
    }

    public func setAfkImmune(_ activityId: Int64, _ immune: Bool) {
        if immune { afkImmune.insert(activityId) } else { afkImmune.remove(activityId) }
    }

    public func isAfkImmune(_ activityId: Int64) -> Bool { afkImmune.contains(activityId) }
}
