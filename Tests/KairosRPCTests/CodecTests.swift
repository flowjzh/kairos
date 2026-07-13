import Testing
@testable import KairosRPC

@Suite
struct CodecTests {
    // MARK: JSONValue fidelity

    @Test
    func intValueEncodesAsInt() throws {
        let v = try Wire.encodeValue(Int64(42))
        #expect(v == .int(42))
    }

    @Test
    func doubleValueEncodesAsDouble() throws {
        let v = try Wire.encodeValue(1.5)
        #expect(v == .double(1.5))
    }

    @Test
    func parsesScalarJSON() throws {
        #expect(try Wire.parse("42") == .int(42))
        #expect(try Wire.parse("42.5") == .double(42.5))
        #expect(try Wire.parse("true") == .bool(true))
        #expect(try Wire.parse("\"hi\"") == .string("hi"))
        #expect(try Wire.parse("null") == .null)
    }

    @Test
    func parsesNestedJSON() throws {
        let v = try Wire.parse("{\"a\":1,\"b\":[1,2]}")
        #expect(v == .object(["a": .int(1), "b": .array([.int(1), .int(2)])]))
    }

    // MARK: Request round-trip

    @Test
    func eventsPostRequestRoundTrip() throws {
        let params = EventsPostParams(
            activity: ActivityRef(source: "claude-code", externalId: "abc-123"),
            kind: "ai_submit",
            ts: 1783739062.0,
            payload: nil
        )
        let env = RequestEnvelope(method: .eventsPost, params: try Wire.encodeValue(params))
        let line = try LineCodec.encodeRequest(env)

        #expect(!line.contains("\n"))
        #expect(line.contains("\"method\":\"events.post\""))
        #expect(line.contains("\"external_id\":\"abc-123\""))

        let back = try LineCodec.decodeRequest(line)
        #expect(back.method == .eventsPost)
        let p = try Wire.decodeValue(back.params, as: EventsPostParams.self)
        #expect(p.kind == "ai_submit")
        #expect(p.activity?.externalId == "abc-123")
        #expect(p.ts == 1783739062.0)
    }

    @Test
    func eventsPostWithPayloadRoundTrip() throws {
        let payload = try Wire.parse("{\"transcript_path\":\"/x/y.jsonl\"}")
        let params = EventsPostParams(activity: nil, kind: "afk_on", ts: 1.0, payload: payload)
        let env = RequestEnvelope(method: .eventsPost, params: try Wire.encodeValue(params))
        let line = try LineCodec.encodeRequest(env)

        let back = try LineCodec.decodeRequest(line)
        let p = try Wire.decodeValue(back.params, as: EventsPostParams.self)
        #expect(p.activity == nil)
        #expect(p.payload == payload)
    }

    // MARK: Response round-trip

    @Test
    func errorResponseRoundTrip() throws {
        let resp: ResponseEnvelope = .error(RPCError(code: "bad_request", message: "ts in the future"))
        let line = try LineCodec.encodeResponse(resp)
        let back = try LineCodec.decodeResponse(line)

        guard case .error(let e) = back else {
            Issue.record("expected error envelope")
            return
        }
        #expect(e.code == "bad_request")
        #expect(e.message == "ts in the future")
    }

    @Test
    func resultResponseRoundTrip() throws {
        let result = ActivitiesOpenResult(activityId: 42)
        let resp: ResponseEnvelope = .result(try Wire.encodeValue(result))
        let line = try LineCodec.encodeResponse(resp)
        let back = try LineCodec.decodeResponse(line)

        guard case .result(let v) = back else {
            Issue.record("expected result envelope")
            return
        }
        let r = try Wire.decodeValue(v, as: ActivitiesOpenResult.self)
        #expect(r.activityId == 42)
    }

    @Test
    func segmentsGetResultRoundTrip() throws {
        let result = SegmentsGetResult(
            segments: [WireSegment(activityId: 1, start: 100, end: 200, seconds: 100, rule: "explicit")],
            activities: [
                "1": WireActivity(
                    source: "claude-code",
                    externalId: "s",
                    project: "daemonclaw",
                    title: "t",
                    client: WireClient(id: 7, name: "Acme"),
                    billable: true,
                    metadata: nil
                )
            ]
        )
        let resp: ResponseEnvelope = .result(try Wire.encodeValue(result))
        let line = try LineCodec.encodeResponse(resp)
        let back = try LineCodec.decodeResponse(line)

        guard case .result(let v) = back else {
            Issue.record("expected result envelope")
            return
        }
        let r = try Wire.decodeValue(v, as: SegmentsGetResult.self)
        #expect(r.segments.count == 1)
        #expect(r.segments[0].activityId == 1)
        #expect(r.segments[0].seconds == 100)
        #expect(r.activities["1"]?.client?.id == 7)
        #expect(r.activities["1"]?.project == "daemonclaw")
    }

    // MARK: Errors

    @Test
    func unknownMethodThrows() {
        #expect(throws: RPCDecodeError.self) {
            try LineCodec.decodeRequest("{\"method\":\"bogus.method\",\"params\":{}}")
        }
    }

    @Test
    func malformedLineThrows() {
        #expect(throws: RPCDecodeError.self) {
            try LineCodec.decodeRequest("not json at all")
        }
    }
}
