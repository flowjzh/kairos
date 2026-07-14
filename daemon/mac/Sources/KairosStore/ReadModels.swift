import Foundation
import KairosCore

/// Read-model types returned by `Store` queries. The daemon maps these to the
/// KairosRPC wire types (Client → ClientEntry, etc.); the Store itself does
/// not depend on KairosRPC.

public struct Client: Sendable, Equatable {
    public let id: Int64
    public let name: String

    public init(id: Int64, name: String) {
        self.id = id
        self.name = name
    }
}

public struct ProjectMapping: Sendable, Equatable {
    public let project: String
    public let clientId: Int64?
    public let billable: Bool

    public init(project: String, clientId: Int64?, billable: Bool) {
        self.project = project
        self.clientId = clientId
        self.billable = billable
    }
}

public struct ResolvedClient: Sendable, Equatable {
    public let clientId: Int64?
    public let billable: Bool

    public init(clientId: Int64?, billable: Bool) {
        self.clientId = clientId
        self.billable = billable
    }
}

/// A single activity row joined to its source/project slugs.
public struct ActivityRecord: Sendable, Equatable {
    public let id: Int64
    public let source: String
    public let externalId: String?
    public let project: String?
    public let title: String?
    public let metadata: Data?
    /// The activity's source is user-managed (`manual`) vs tool-created (`auto`).
    public let manual: Bool
    /// The source's human-facing label (e.g. `pty` → "Terminal"), for the menu.
    public let displayName: String

    public init(id: Int64, source: String, externalId: String?, project: String?, title: String?, metadata: Data?, manual: Bool, displayName: String) {
        self.id = id
        self.source = source
        self.externalId = externalId
        self.project = project
        self.title = title
        self.metadata = metadata
        self.manual = manual
        self.displayName = displayName
    }
}

/// An activity plus its resolved client — the per-activity detail a consumer
/// needs alongside a segment.
public struct ActivityDetail: Sendable, Equatable {
    public let record: ActivityRecord
    public let client: ResolvedClient
    public let clientName: String?

    public init(record: ActivityRecord, client: ResolvedClient, clientName: String?) {
        self.record = record
        self.client = client
        self.clientName = clientName
    }
}

/// The attributed-segments read result: computed segments + per-activity detail.
public struct AttributedSegments: Sendable {
    public let segments: [Segment]
    public let activities: [Int64: ActivityDetail]

    public init(segments: [Segment], activities: [Int64: ActivityDetail]) {
        self.segments = segments
        self.activities = activities
    }
}
