//! The one C-ABI boundary between a native host (today the Swift daemon; later a
//! Windows shell / Tauri) and Kairos' Rust modules. Every capability the host
//! needs from Rust is a `#[no_mangle] extern "C"` function here; the domain
//! crates (`libs/report`, later `libs/store`/`libs/core`) stay pure and this
//! crate is the only `staticlib`. Adding a capability = one function here + one
//! line in the C header — the general plug-in point.
//!
//! ## Marshaling convention
//!
//! The volume input (segments — up to tens of thousands over a year) crosses as
//! a **packed little-endian buffer**, read in place; the bounded, string-heavy
//! side (the activities map) crosses as a **JSON string**. Results are small
//! (aggregated) and returned as a malloc'd NUL-terminated JSON string the caller
//! frees via [`kairos_string_free`]. A decode failure returns null.

use std::collections::HashMap;
use std::ffi::{c_char, CStr, CString};
use std::slice;

use kairos_report::{Activity, Segment};

/// Packed segment record: `[i64 activity_id][f64 start][f64 end][f64 seconds]`,
/// little-endian, no padding.
const RECORD_SIZE: usize = 32;

// --- shared marshaling substrate (reused by every entry point) ---

fn into_c_string(s: String) -> *mut c_char {
    CString::new(s).map_or(std::ptr::null_mut(), CString::into_raw)
}

fn read_i64(b: &[u8]) -> i64 {
    i64::from_le_bytes(b[..8].try_into().unwrap())
}

fn read_f64(b: &[u8]) -> f64 {
    f64::from_le_bytes(b[..8].try_into().unwrap())
}

/// Decode the packed segment buffer + activities JSON into pure report inputs.
/// `None` on any malformed input.
///
/// `activities_json` is a JSON **object** keyed by the stringified activity id
/// (JSON object keys are strings), decoded into `HashMap<i64, Activity>` — so a
/// host must not send an Int64-keyed map serialized as a flat array.
///
/// # Safety
/// `seg_ptr` must point to `count * RECORD_SIZE` readable bytes (or `count == 0`);
/// `activities_json` must be a valid NUL-terminated UTF-8 C string.
unsafe fn decode_inputs(
    seg_ptr: *const u8,
    count: usize,
    activities_json: *const c_char,
) -> Option<(Vec<Segment>, HashMap<i64, Activity>)> {
    if activities_json.is_null() {
        return None;
    }
    let bytes: &[u8] = if count == 0 { &[] } else { slice::from_raw_parts(seg_ptr, count * RECORD_SIZE) };
    let segments = (0..count)
        .map(|i| {
            let r = &bytes[i * RECORD_SIZE..];
            Segment { activity_id: read_i64(r), start: read_f64(&r[8..]), end: read_f64(&r[16..]), seconds: read_f64(&r[24..]) }
        })
        .collect();

    let json = CStr::from_ptr(activities_json).to_str().ok()?;
    let activities: HashMap<i64, Activity> = serde_json::from_str(json).ok()?;
    Some((segments, activities))
}

// --- report entry points ---

/// Overview (timeline + summary tree + totals) for `[from, to]`.
///
/// # Safety
/// See [`decode_inputs`]. The returned pointer is owned by the caller (free via
/// [`kairos_string_free`]).
#[no_mangle]
pub unsafe extern "C" fn kairos_report_overview(
    seg_ptr: *const u8,
    count: usize,
    activities_json: *const c_char,
    from: f64,
    to: f64,
) -> *mut c_char {
    let Some((segments, activities)) = decode_inputs(seg_ptr, count, activities_json) else {
        return std::ptr::null_mut();
    };
    let out = kairos_report::overview(&segments, &activities, from, to);
    serde_json::to_string(&out).map_or(std::ptr::null_mut(), into_c_string)
}

/// One page of raw rows (newest first) plus the full resolvable count.
///
/// # Safety
/// See [`decode_inputs`]. The returned pointer is owned by the caller (free via
/// [`kairos_string_free`]).
#[no_mangle]
pub unsafe extern "C" fn kairos_report_segments(
    seg_ptr: *const u8,
    count: usize,
    activities_json: *const c_char,
    offset: usize,
    limit: usize,
) -> *mut c_char {
    let Some((segments, activities)) = decode_inputs(seg_ptr, count, activities_json) else {
        return std::ptr::null_mut();
    };
    let out = kairos_report::segments_page(&segments, &activities, offset, limit);
    serde_json::to_string(&out).map_or(std::ptr::null_mut(), into_c_string)
}

/// Free a string returned by this library. No-op on null.
///
/// # Safety
/// `ptr` must be a pointer previously returned by an entry point here, freed once.
#[no_mangle]
pub unsafe extern "C" fn kairos_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        drop(CString::from_raw(ptr));
    }
}
