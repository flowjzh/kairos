//! Port of `KairosRPCTests/{CodecTests,MethodTests}.swift` — the wire-fidelity
//! contract: Rust `libs/codec` must round-trip the same JSON the Swift daemon
//! produces/consumes.

use kairos_codec::*;
use serde_json::json;

#[test]
fn method_raw_values_match_spec() {
    assert_eq!(serde_json::to_value(Method::ActivitiesOpen).unwrap(), json!("activities.open"));
    assert_eq!(serde_json::to_value(Method::ActivitiesClose).unwrap(), json!("activities.close"));
    assert_eq!(serde_json::to_value(Method::EventsPost).unwrap(), json!("events.post"));
    assert_eq!(serde_json::to_value(Method::FocusReport).unwrap(), json!("focus.report"));
    assert_eq!(serde_json::to_value(Method::ControlPause).unwrap(), json!("control.pause"));
    assert_eq!(serde_json::to_value(Method::ControlOwner).unwrap(), json!("control.owner"));
    assert_eq!(serde_json::to_value(Method::ClientsList).unwrap(), json!("clients.list"));
    assert_eq!(serde_json::to_value(Method::ClientsAdd).unwrap(), json!("clients.add"));
    assert_eq!(serde_json::to_value(Method::ClientsRename).unwrap(), json!("clients.rename"));
    assert_eq!(serde_json::to_value(Method::MappingList).unwrap(), json!("mapping.list"));
    assert_eq!(serde_json::to_value(Method::MappingSet).unwrap(), json!("mapping.set"));
    assert_eq!(serde_json::to_value(Method::SegmentsGet).unwrap(), json!("segments.get"));
    assert_eq!(serde_json::to_value(Method::OwnerGet).unwrap(), json!("owner.get"));
}

// JSONValue fidelity → serde_json Value preserves int vs float.

#[test]
fn int_value_stays_int() {
    let v = serde_json::to_value(42i64).unwrap();
    assert!(v.is_i64());
    assert_eq!(v.as_i64(), Some(42));
    assert_eq!(v.to_string(), "42"); // not 42.0
}

#[test]
fn double_value_stays_double() {
    let v = serde_json::to_value(1.5f64).unwrap();
    assert!(v.is_f64());
    assert_eq!(v.as_f64(), Some(1.5));
}

#[test]
fn parses_scalar_json() {
    assert!(serde_json::from_str::<Value>("42").unwrap().is_i64());
    assert!(serde_json::from_str::<Value>("42.5").unwrap().is_f64());
    assert_eq!(serde_json::from_str::<Value>("true").unwrap().as_bool(), Some(true));
    assert_eq!(serde_json::from_str::<Value>(r#""hi""#).unwrap().as_str(), Some("hi"));
    assert!(serde_json::from_str::<Value>("null").unwrap().is_null());
}

#[test]
fn parses_nested_json() {
    let v: Value = serde_json::from_str(r#"{"a":1,"b":[1,2]}"#).unwrap();
    assert_eq!(v["a"].as_i64(), Some(1));
    assert_eq!(v["b"][0].as_i64(), Some(1));
    assert_eq!(v["b"][1].as_i64(), Some(2));
}

// Request round-trip.

#[test]
fn events_post_request_round_trip() {
    let params = EventsPostParams {
        activity: Some(ActivityRef {
            source: "claude-code".into(),
            external_id: Some("abc-123".into()),
        }),
        kind: "ai_submit".into(),
        ts: 1783739062.0,
        payload: None,
        kairos_session_id: None,
    };
    let env = RequestEnvelope::new(Method::EventsPost, serde_json::to_value(&params).unwrap());
    let line = encode_request(&env).unwrap();

    assert!(!line.contains('\n'));
    assert!(line.contains(r#""method":"events.post""#));
    assert!(line.contains(r#""external_id":"abc-123""#));

    let back = decode_request(&line).unwrap();
    assert_eq!(back.method, Method::EventsPost);
    let p: EventsPostParams = serde_json::from_value(back.params).unwrap();
    assert_eq!(p.kind, "ai_submit");
    assert_eq!(p.activity.unwrap().external_id.unwrap(), "abc-123");
    assert_eq!(p.ts, 1783739062.0);
}

#[test]
fn events_post_with_payload_round_trip() {
    let payload: Value = serde_json::from_str(r#"{"transcript_path":"/x/y.jsonl"}"#).unwrap();
    let params = EventsPostParams {
        activity: None,
        kind: "afk_on".into(),
        ts: 1.0,
        payload: Some(payload.clone()),
        kairos_session_id: None,
    };
    let env = RequestEnvelope::new(Method::EventsPost, serde_json::to_value(&params).unwrap());
    let line = encode_request(&env).unwrap();

    let back = decode_request(&line).unwrap();
    let p: EventsPostParams = serde_json::from_value(back.params).unwrap();
    assert!(p.activity.is_none());
    assert_eq!(p.payload, Some(payload));
}

// Response round-trip.

#[test]
fn error_response_round_trip() {
    let resp = ResponseEnvelope::Error(RpcError::new("bad_request", "ts in the future"));
    let line = encode_response(&resp).unwrap();
    let back = decode_response(&line).unwrap();
    match back {
        ResponseEnvelope::Error(e) => {
            assert_eq!(e.code, "bad_request");
            assert_eq!(e.message, "ts in the future");
        }
        _ => panic!("expected error envelope"),
    }
}

#[test]
fn result_response_round_trip() {
    let result = ActivitiesOpenResult { activity_id: 42 };
    let resp = ResponseEnvelope::Result(serde_json::to_value(&result).unwrap());
    let line = encode_response(&resp).unwrap();
    let back = decode_response(&line).unwrap();
    match back {
        ResponseEnvelope::Result(v) => {
            let r: ActivitiesOpenResult = serde_json::from_value(v).unwrap();
            assert_eq!(r.activity_id, 42);
        }
        _ => panic!("expected result envelope"),
    }
}

#[test]
fn segments_get_result_round_trip() {
    let result = SegmentsGetResult {
        segments: vec![WireSegment {
            activity_id: 1,
            start: 100.0,
            end: 200.0,
            seconds: 100.0,
            rule: "explicit".into(),
        }],
        activities: [(
            "1".to_string(),
            WireActivity {
                source: "claude-code".into(),
                external_id: Some("s".into()),
                project: Some("daemonclaw".into()),
                title: Some("t".into()),
                client: Some(WireClient { id: 7, name: "Acme".into() }),
                billable: true,
                metadata: None,
            },
        )]
        .into_iter()
        .collect(),
    };
    let resp = ResponseEnvelope::Result(serde_json::to_value(&result).unwrap());
    let line = encode_response(&resp).unwrap();
    let back = decode_response(&line).unwrap();
    match back {
        ResponseEnvelope::Result(v) => {
            let r: SegmentsGetResult = serde_json::from_value(v).unwrap();
            assert_eq!(r.segments.len(), 1);
            assert_eq!(r.segments[0].activity_id, 1);
            assert_eq!(r.segments[0].seconds, 100.0);
            assert_eq!(r.activities.get("1").unwrap().client.as_ref().unwrap().id, 7);
            assert_eq!(r.activities.get("1").unwrap().project.as_deref(), Some("daemonclaw"));
        }
        _ => panic!("expected result envelope"),
    }
}

// Errors.

#[test]
fn unknown_method_throws() {
    assert_eq!(
        decode_request(r#"{"method":"bogus.method","params":{}}"#).unwrap_err(),
        DecodeError::UnknownMethod
    );
}

#[test]
fn malformed_line_throws() {
    assert_eq!(decode_request("not json at all").unwrap_err(), DecodeError::MalformedLine);
}
