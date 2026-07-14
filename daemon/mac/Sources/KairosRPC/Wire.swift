import Foundation

/// JSON encoding/decoding helpers. Two encoder/decoder pairs:
///
/// - `jsonEncoder`/`jsonDecoder` (no key strategy): for `JSONValue` and the
///   request/response envelopes. Object keys pass through verbatim, so an
///   already-snake_case key like `external_id` is preserved.
/// - `structEncoder`/`structDecoder` (snake_case strategy): for the typed
///   params/result structs, so Swift `externalId` maps to wire `external_id`.
public enum Wire {
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    static let jsonDecoder = JSONDecoder()

    static let structEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.keyEncodingStrategy = .convertToSnakeCase
        return e
    }()

    static let structDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// Encode a typed value to an opaque `JSONValue` (snake_case keys).
    public static func encodeValue<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try structEncoder.encode(value)
        return try jsonDecoder.decode(JSONValue.self, from: data)
    }

    /// Decode an opaque `JSONValue` into a typed value (snake_case → camelCase).
    public static func decodeValue<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        let data = try jsonEncoder.encode(value)
        return try structDecoder.decode(T.self, from: data)
    }

    /// Parse any JSON text into a `JSONValue`.
    public static func parse(_ jsonString: String) throws -> JSONValue {
        try jsonDecoder.decode(JSONValue.self, from: Data(jsonString.utf8))
    }

    /// Encode any `Encodable` to raw JSON `Data` (keys preserved verbatim).
    public static func data<T: Encodable>(_ value: T) throws -> Data {
        try jsonEncoder.encode(value)
    }

    /// Decode raw JSON `Data` into a `JSONValue` (keys preserved verbatim).
    public static func decode(jsonData: Data) throws -> JSONValue {
        try jsonDecoder.decode(JSONValue.self, from: jsonData)
    }
}
