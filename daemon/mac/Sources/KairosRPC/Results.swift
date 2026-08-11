import Foundation

public struct EmptyResult: Codable, Sendable, Equatable {
    public init() {}
}

public struct ActivitiesStartResult: Codable, Sendable, Equatable {
    public let activityId: Int64

    public init(activityId: Int64) { self.activityId = activityId }
}

public struct ClientEntry: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ClientsListResult: Codable, Sendable, Equatable {
    public let clients: [ClientEntry]

    public init(clients: [ClientEntry]) { self.clients = clients }
}

public struct ClientsAddResult: Codable, Sendable, Equatable {
    public let id: Int64

    public init(id: Int64) { self.id = id }
}

public struct MappingEntry: Codable, Sendable, Equatable {
    public let project: String
    public let clientId: Int64?
    public let billable: Bool

    public init(project: String, clientId: Int64?, billable: Bool) {
        self.project = project
        self.clientId = clientId
        self.billable = billable
    }
}

public struct MappingListResult: Codable, Sendable, Equatable {
    public let map: [MappingEntry]

    public init(map: [MappingEntry]) { self.map = map }
}

public struct WireSegment: Codable, Sendable, Equatable {
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

public struct WireClient: Codable, Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct WireActivity: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let project: String?
    public let title: String?
    public let client: WireClient?
    public let billable: Bool
    public let metadata: [String: JSONValue]?

    public init(source: String, externalId: String?, project: String?, title: String?, client: WireClient?, billable: Bool, metadata: [String: JSONValue]?) {
        self.source = source
        self.externalId = externalId
        self.project = project
        self.title = title
        self.client = client
        self.billable = billable
        self.metadata = metadata
    }
}

public struct SegmentsGetResult: Codable, Sendable, Equatable {
    public let segments: [WireSegment]
    public let activities: [String: WireActivity]

    public init(segments: [WireSegment], activities: [String: WireActivity]) {
        self.segments = segments
        self.activities = activities
    }
}

public struct FocusedActivity: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let project: String?
    public let title: String?

    public init(source: String, externalId: String?, project: String?, title: String?) {
        self.source = source
        self.externalId = externalId
        self.project = project
        self.title = title
    }
}

public struct FocusedGetResult: Codable, Sendable, Equatable {
    public let activity: FocusedActivity?

    public init(activity: FocusedActivity?) { self.activity = activity }
}

/// One statusline field: a localized visible `label`, the `text` to show (nil
/// when the field has no value, e.g. an activity with no title), and an optional
/// stable color key the client maps to ANSI.
public struct ActivityStatusField: Codable, Sendable, Equatable {
    public let label: String
    public let text: String?
    public let color: String?

    public init(label: String, text: String?, color: String?) {
        self.label = label
        self.text = text
        self.color = color
    }
}

/// `activities.status` result — a flat dict whose keys are either the four
/// normal fields or a single `error` field, never both (a producer contract
/// enforced in the daemon handler). All fields optional so nil keys are omitted
/// on encode (matches Rust's per-field `skip_serializing_if`).
public struct ActivityStatusResult: Codable, Sendable, Equatable {
    /// The activity's display name (title ?? project), resolved daemon-side.
    /// Labeled "Activity"/"活动".
    public let activity: ActivityStatusField?
    public let state: ActivityStatusField?
    public let total: ActivityStatusField?
    public let today: ActivityStatusField?
    public let error: ActivityStatusField?

    public init(activity: ActivityStatusField? = nil, state: ActivityStatusField? = nil, total: ActivityStatusField? = nil, today: ActivityStatusField? = nil, error: ActivityStatusField? = nil) {
        self.activity = activity
        self.state = state
        self.total = total
        self.today = today
        self.error = error
    }
}
