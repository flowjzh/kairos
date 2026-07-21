//! Round-trip the C ABI: pack the buffer + activities JSON exactly as the Swift
//! host will, call the entry points, parse the returned JSON.

use std::ffi::{c_char, CStr, CString};

use kairos_ffi::{kairos_report_overview, kairos_report_segments, kairos_string_free};

fn pack(segments: &[(i64, f64, f64, f64)]) -> Vec<u8> {
    let mut buf = Vec::with_capacity(segments.len() * 32);
    for &(id, start, end, seconds) in segments {
        buf.extend_from_slice(&id.to_le_bytes());
        buf.extend_from_slice(&start.to_le_bytes());
        buf.extend_from_slice(&end.to_le_bytes());
        buf.extend_from_slice(&seconds.to_le_bytes());
    }
    buf
}

unsafe fn take(ptr: *mut c_char) -> serde_json::Value {
    assert!(!ptr.is_null(), "entry point returned null");
    let v = serde_json::from_str(CStr::from_ptr(ptr).to_str().unwrap()).unwrap();
    kairos_string_free(ptr);
    v
}

#[test]
fn overview_and_segments_round_trip() {
    let buf = pack(&[(1, 0.0, 300.0, 300.0), (2, 0.0, 120.0, 120.0)]);
    let activities = CString::new(
        r#"{"1":{"source":"pty","display_name":"Terminal","project":"p1","title":null,"client_id":1,"client_name":"Acme","billable":true},
            "2":{"source":"claude-code","display_name":"Claude","project":null,"title":null,"client_id":null,"client_name":null,"billable":false}}"#,
    )
    .unwrap();

    let o = unsafe { take(kairos_report_overview(buf.as_ptr(), 2, activities.as_ptr(), 0.0, 600.0)) };
    assert_eq!(o["total"], 2);
    assert_eq!(o["total_seconds"], 420.0);
    assert_eq!(o["timeline"]["series"].as_array().unwrap().len(), 2);
    // Acme (billable) sorts before the unassigned client.
    assert_eq!(o["summary"][0]["client_id"], 1);
    assert_eq!(o["summary"][1]["client_id"], serde_json::Value::Null);

    let p = unsafe { take(kairos_report_segments(buf.as_ptr(), 2, activities.as_ptr(), 0, 100)) };
    assert_eq!(p["total"], 2);
    assert_eq!(p["segments"].as_array().unwrap().len(), 2);
}

#[test]
fn empty_input_is_safe() {
    let activities = CString::new("{}").unwrap();
    let o = unsafe { take(kairos_report_overview(std::ptr::null(), 0, activities.as_ptr(), 0.0, 600.0)) };
    assert_eq!(o["total"], 0);
}

#[test]
fn malformed_activities_returns_null() {
    let buf = pack(&[(1, 0.0, 300.0, 300.0)]);
    let bad = CString::new("not json").unwrap();
    let ptr = unsafe { kairos_report_overview(buf.as_ptr(), 1, bad.as_ptr(), 0.0, 600.0) };
    assert!(ptr.is_null());
}
