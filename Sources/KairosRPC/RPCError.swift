import Foundation

/// An error carried in a `{"error":{"code","message"}}` response.
public struct RPCError: Error, Codable, Sendable, Equatable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

/// A local failure to decode a request/response line.
public enum RPCDecodeError: Error, Sendable {
    case malformedLine
    case unknownMethod
    case malformedResponse
}
