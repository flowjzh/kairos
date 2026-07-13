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

public struct ActivitiesOpenParams: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let project: String?
    public let title: String?
    public let metadata: [String: JSONValue]?

    public init(source: String, externalId: String?, project: String?, title: String?, metadata: [String: JSONValue]?) {
        self.source = source
        self.externalId = externalId
        self.project = project
        self.title = title
        self.metadata = metadata
    }
}

public struct ActivitiesCloseParams: Codable, Sendable, Equatable {
    public let source: String
    public let externalId: String?
    public let ts: Double

    public init(source: String, externalId: String?, ts: Double) {
        self.source = source
        self.externalId = externalId
        self.ts = ts
    }
}

public struct EventsPostParams: Codable, Sendable, Equatable {
    public let activity: ActivityRef?
    public let kind: String
    public let ts: Double
    public let payload: JSONValue?

    public init(activity: ActivityRef?, kind: String, ts: Double, payload: JSONValue?) {
        self.activity = activity
        self.kind = kind
        self.ts = ts
        self.payload = payload
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

public struct ControlOwnerParams: Codable, Sendable, Equatable {
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
