import Foundation

/// `{source, external_id}` — identifies an activity on the wire (slugs/strings).
public struct ActivityRef: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?

    public init(source: String, externalId: String?) {
        self.source = source
        self.externalId = externalId
    }
}

public struct ActivitiesStartParams: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let project: String?
    public let title: String?
    public let metadata: [String: JSONValue]?
    /// The wrapping `kairos` PTY session, when launched under one — lets the
    /// daemon route this activity's focus reports by kid (M4).
    public let kairosSessionId: String?
    /// Manual activities may disable AFK detection while focused (passive work).
    public let afkImmune: Bool?
    /// Human-facing name for this source (the plugin owns its label); recorded on
    /// `sources.display_name`. Built-in `pty` is seeded with "Terminal" instead.
    public let sourceDisplayName: String?

    public init(source: String, externalId: String?, project: String?, title: String?, metadata: [String: JSONValue]?, kairosSessionId: String? = nil, afkImmune: Bool? = nil, sourceDisplayName: String? = nil) {
        self.source = source
        self.externalId = externalId
        self.project = project
        self.title = title
        self.metadata = metadata
        self.kairosSessionId = kairosSessionId
        self.afkImmune = afkImmune
        self.sourceDisplayName = sourceDisplayName
    }
}

/// Stop (→ state=stopped). Resolvable by `(source, external_id)` (a hook's
/// SessionEnd / the menu) or by `kairos_session_id` (the wrapper's exit).
public struct ActivitiesStopParams: Codable, Sendable, Equatable {
    public let source: String?
    public let externalId: String?
    public let kairosSessionId: String?
    public let ts: Double

    public init(source: String?, externalId: String?, kairosSessionId: String? = nil, ts: Double) {
        self.source = source
        self.externalId = externalId
        self.kairosSessionId = kairosSessionId
        self.ts = ts
    }
}

/// The wrapper's post-launch (~5 s) call: create a `pty` activity ONLY if the
/// kid is still unclaimed by a hook (idempotent). Design B (M4p3).
public struct ActivitiesEnsureParams: Codable, Sendable, Equatable {
    public let kairosSessionId: String
    public let source: String
    public let project: String?
    public let title: String?
    public let ts: Double

    public init(kairosSessionId: String, source: String, project: String?, title: String?, ts: Double) {
        self.kairosSessionId = kairosSessionId
        self.source = source
        self.project = project
        self.title = title
        self.ts = ts
    }
}

/// `activities.status` — per-session statusline payload for one activity,
/// addressed by its `(source, external_id)` identity.
public struct ActivitiesStatusParams: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String

    public init(source: String, externalId: String) {
        self.source = source
        self.externalId = externalId
    }
}

public struct EventsPostParams: Codable, Sendable, Equatable {
    public let activity: ActivityRef?
    public let kind: String
    public let ts: Double
    public let payload: JSONValue?
    public let kairosSessionId: String?

    public init(activity: ActivityRef?, kind: String, ts: Double, payload: JSONValue?, kairosSessionId: String? = nil) {
        self.activity = activity
        self.kind = kind
        self.ts = ts
        self.payload = payload
        self.kairosSessionId = kairosSessionId
    }
}

/// A terminal focus transition from the `kairos` PTY wrapper, keyed by the
/// wrapper session. The daemon resolves `kairosSessionId` to an activity (via the
/// hook-populated map) and appends `focus`/`blur` (M4; generic — any future focus
/// reporter).
public struct FocusReportParams: Codable, Sendable, Equatable {
    public let kairosSessionId: String
    public let focused: Bool
    public let ts: Double

    public init(kairosSessionId: String, focused: Bool, ts: Double) {
        self.kairosSessionId = kairosSessionId
        self.focused = focused
        self.ts = ts
    }
}

public struct ControlPauseParams: Codable, Sendable, Equatable {
    public let paused: Bool
    public let ts: Double

    public init(paused: Bool, ts: Double) {
        self.paused = paused
        self.ts = ts
    }
}

/// A plugin's request to nudge the user with a native notification (e.g. the
/// agent launched without `kairos`, so focus/blur is missing). The plugin owns
/// the decision and the wording; the daemon only delivers and cooldown-gates by
/// `(source, kind)`, so those two fields are the dedup key. Mirrors the Rust
/// codec `NotifyUserParams`.
public struct NotifyUserParams: Codable, Sendable, Equatable {
    public let source: String
    public let kind: String
    public let title: String
    /// Optional secondary line under the title (rendered smaller); used to set
    /// the command apart on its own line — the platform has no inline code style.
    public let subtitle: String?
    public let message: String
    /// If set, the daemon delivers at most once per this many seconds per
    /// `(source, kind)`; `nil` (default) → deliver every call.
    public let cooldownSeconds: Double?

    public init(source: String, kind: String, title: String, message: String, subtitle: String? = nil, cooldownSeconds: Double? = nil) {
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.message = message
        self.cooldownSeconds = cooldownSeconds
    }
}

/// Manual focus switch from the menu (→ a `focus` event); replaces the removed
/// `force_owner` (M4p3).
public struct FocusSetParams: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let ts: Double

    public init(source: String, externalId: String?, ts: Double) {
        self.source = source
        self.externalId = externalId
        self.ts = ts
    }
}

public struct ClientsAddParams: Codable, Sendable, Equatable {
    public let name: String

    public init(name: String) { self.name = name }
}

public struct ClientsRenameParams: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct MappingSetParams: Codable, Sendable, Equatable {
    public let project: String
    public let clientId: Int64?
    public let billable: Bool

    public init(project: String, clientId: Int64?, billable: Bool) {
        self.project = project
        self.clientId = clientId
        self.billable = billable
    }
}

public struct SegmentsGetParams: Codable, Sendable, Equatable {
    public let from: Double
    public let to: Double
    public let project: String?
    public let client: Int64?

    public init(from: Double, to: Double, project: String?, client: Int64?) {
        self.from = from
        self.to = to
        self.project = project
        self.client = client
    }
}
