import Foundation

/// A request line: `{"method":"...","params":{...}}`.
public struct RequestEnvelope: Codable, Sendable, Equatable {
    public let method: Method
    public let params: JSONValue

    public init(method: Method, params: JSONValue) {
        self.method = method
        self.params = params
    }
}

/// A response line: `{"result":...}` or `{"error":{"code","message"}}`.
public enum ResponseEnvelope: Codable, Sendable, Equatable {
    case result(JSONValue)
    case error(RPCError)

    private enum CodingKeys: String, CodingKey { case result, error }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let err = try? c.decode(RPCError.self, forKey: .error) {
            self = .error(err)
        } else if let res = try? c.decode(JSONValue.self, forKey: .result) {
            self = .result(res)
        } else {
            throw RPCDecodeError.malformedResponse
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .result(let v): try c.encode(v, forKey: .result)
        case .error(let e): try c.encode(e, forKey: .error)
        }
    }
}
