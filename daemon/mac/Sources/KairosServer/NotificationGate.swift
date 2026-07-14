import Foundation

/// What the delivery seam renders — the presentation half of a notification,
/// separated from `NotifyUserParams`'s routing/throttle fields (`source`, `kind`,
/// `cooldownSeconds`) so the UI-free `KairosServer` hands `KairosDaemon` only
/// what it draws. Policy is resolved inside `Dispatcher` before this is built.
public struct NotificationContent: Sendable, Equatable {
    public let title: String
    public let subtitle: String?
    public let message: String

    public init(title: String, subtitle: String? = nil, message: String) {
        self.title = title
        self.subtitle = subtitle
        self.message = message
    }
}

/// Opt-in, per-`(source, kind)` cooldown for `notify.user`. Throttling is a
/// per-request choice: a `notify.user` that sends `cooldown_seconds` is gated
/// (at most one delivery per window per key); one that omits it is delivered
/// every time. Ephemeral (mirrors `SessionRegistry`): in-memory, resets on a
/// daemon restart.
public actor NotificationGate {
    private var lastShown: [String: Date] = [:]
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// True iff `key` hasn't been shown within `cooldown` seconds. Records the
    /// show time only when returning `true`, so the next allowed call lands a
    /// full `cooldown` after the last shown.
    public func allow(_ key: String, cooldown: TimeInterval) -> Bool {
        let t = now()
        if let last = lastShown[key], t.timeIntervalSince(last) < cooldown { return false }
        lastShown[key] = t
        return true
    }
}
