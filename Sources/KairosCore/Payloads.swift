import Foundation

/// Codable shapes for event `payload` JSON, so encode/decode goes through one
/// codec instead of hand-rolled `JSONSerialization`. Both fields optional:
/// producers emit only what they set; resolution defaults the rest.

/// `activity_override` payload (docs/03).
public struct OverridePayload: Codable, Sendable {
    public let clientId: Int64?
    public let billable: Bool?

    public init(clientId: Int64?, billable: Bool?) {
        self.clientId = clientId
        self.billable = billable
    }

    enum CodingKeys: String, CodingKey { case clientId = "client_id"; case billable }
}

/// `afk_on` payload (docs/06): why the afk span began.
public struct AfkOnPayload: Codable, Sendable {
    public let reason: String

    public init(reason: String) { self.reason = reason }
}
