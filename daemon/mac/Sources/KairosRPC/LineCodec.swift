import Foundation

/// Encodes/decodes newline-delimited JSON request/response lines.
/// One JSON object per line, compact (no raw newlines), one request per connection.
public enum LineCodec {
    public static func encodeRequest(_ request: RequestEnvelope) throws -> String {
        let data = try Wire.jsonEncoder.encode(request)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeRequest(_ line: String) throws -> RequestEnvelope {
        let data = Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let raw: RawRequest
        do {
            raw = try Wire.jsonDecoder.decode(RawRequest.self, from: data)
        } catch {
            throw RPCDecodeError.malformedLine
        }
        guard let method = Method(rawValue: raw.method) else {
            throw RPCDecodeError.unknownMethod
        }
        return RequestEnvelope(method: method, params: raw.params)
    }

    public static func encodeResponse(_ response: ResponseEnvelope) throws -> String {
        let data = try Wire.jsonEncoder.encode(response)
        return String(decoding: data, as: UTF8.self)
    }

    public static func decodeResponse(_ line: String) throws -> ResponseEnvelope {
        let data = Data(line.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        do {
            return try Wire.jsonDecoder.decode(ResponseEnvelope.self, from: data)
        } catch {
            throw RPCDecodeError.malformedResponse
        }
    }
}

private struct RawRequest: Codable {
    let method: String
    let params: JSONValue
}
