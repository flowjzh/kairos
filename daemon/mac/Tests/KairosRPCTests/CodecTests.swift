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
    func notifyUserRequestRoundTrip() throws {
        let params = NotifyUserParams(
            source: "claude-code",
            kind: "pty_recommended",
            title: "Run Claude Code via kairos for focus tracking",
            message: "Claude Code started without kairos."
        )
        let env = RequestEnvelope(method: .notifyUser, params: try Wire.encodeValue(params))
        let line = try LineCodec.encodeRequest(env)

        #expect(!line.contains("\n"))
        #expect(line.contains("\"method\":\"notify.user\""))
        #expect(line.contains("\"source\":\"claude-code\""))

        let back = try LineCodec.decodeRequest(line)
        #expect(back.method == .notifyUser)
        let p = try Wire.decodeValue(back.params, as: NotifyUserParams.self)
        #expect(p.kind == "pty_recommended")
        #expect(p.title == "Run Claude Code via kairos for focus tracking")
    }

    @Test
    func resultResponseRoundTrip() throws {
        let result = ActivitiesStartResult(activityId: 42)
        let resp: ResponseEnvelope = .result(try Wire.encodeValue(result))
        let line = try LineCodec.encodeResponse(resp)
        let back = try LineCodec.decodeResponse(line)

        guard case .result(let v) = back else {
            Issue.record("expected result envelope")
            return
        }
        let r = try Wire.decodeValue(v, as: ActivitiesStartResult.self)
        #expect(r.activityId == 42)
    }

    @Test
    func segmentsGetResultRoundTrip() throws {
        let result = SegmentsGetResult(
            segments: [WireSegment(activityId: 1, start: 100, end: 200, seconds: 100, rule: "focus")],
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

    @Test
    func activitiesStatusResultRoundTrip() throws {
        // Normal shape: four fields, nil `error` omitted on the wire.
        let normal = ActivityStatusResult(
            activity: ActivityStatusField(label: "活动", text: "kairos", color: nil),
            state: ActivityStatusField(label: "状态", text: "空闲", color: "gray"),
            total: ActivityStatusField(label: "总计", text: "1h23m", color: nil),
            today: ActivityStatusField(label: "今天", text: "12m", color: nil)
        )
        let line = try LineCodec.encodeResponse(.result(try Wire.encodeValue(normal)))
        #expect(!line.contains("\"error\""), "error key must be absent in normal shape")
        let decoded = try LineCodec.decodeResponse(line)
        guard case .result(let v) = decoded else {
            Issue.record("expected result envelope")
            return
        }
        let back = try Wire.decodeValue(v, as: ActivityStatusResult.self)
        #expect(back.state?.color == "gray")
        #expect(back.activity?.text == "kairos")
        #expect(back.error == nil)

        // Error shape: only the `error` key present.
        let errored = ActivityStatusResult(
            error: ActivityStatusField(label: "错误", text: "未能找到对应的活动", color: "red")
        )
        let errLine = try LineCodec.encodeResponse(.result(try Wire.encodeValue(errored)))
        #expect(errLine.contains("\"error\""))
        #expect(!errLine.contains("\"state\""))
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
