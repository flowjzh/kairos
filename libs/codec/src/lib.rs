//! Canonical Kairos wire protocol: line-delimited JSON RPC over a Unix socket.
//! One compact JSON object per line, one request per connection. This crate is
//! the **canonical** definition of the wire format; the Swift daemon
//! (`daemon/mac/.../KairosRPC`) is a hand-written `Codable` mirror (no codegen,
//! per the daemonclaw pattern). Field names are snake_case; `Method` variants
//! are dotted strings (`activities.open`).

pub mod envelope;
pub mod params;
pub mod results;

pub use envelope::{RequestEnvelope, ResponseEnvelope};
pub use params::*;
pub use results::*;

use serde::{Deserialize, Serialize};

/// RPC method (dotted string). Clients encode; the daemon dispatches. An
/// unknown string fails to decode (mirrors Swift's `Method`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum Method {
    #[serde(rename = "activities.start")]
    ActivitiesStart,
    #[serde(rename = "activities.stop")]
    ActivitiesStop,
    #[serde(rename = "activities.ensure")]
    ActivitiesEnsure,
    #[serde(rename = "events.post")]
    EventsPost,
    #[serde(rename = "focus.report")]
    FocusReport,
    #[serde(rename = "focus.set")]
    FocusSet,
    #[serde(rename = "control.pause")]
    ControlPause,
    #[serde(rename = "notify.user")]
    NotifyUser,
    #[serde(rename = "clients.list")]
    ClientsList,
    #[serde(rename = "clients.add")]
    ClientsAdd,
    #[serde(rename = "clients.rename")]
    ClientsRename,
    #[serde(rename = "mapping.list")]
    MappingList,
    #[serde(rename = "mapping.set")]
    MappingSet,
    #[serde(rename = "segments.get")]
    SegmentsGet,
    #[serde(rename = "focused.get")]
    FocusedGet,
}

/// Error carried in a `{"error":{"code","message"}}` response.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RpcError {
    pub code: String,
    pub message: String,
}

impl RpcError {
    pub fn new(code: impl Into<String>, message: impl Into<String>) -> Self {
        Self { code: code.into(), message: message.into() }
    }
}

/// Failure to decode a request/response line.
#[derive(Debug, PartialEq)]
pub enum DecodeError {
    MalformedLine,
    UnknownMethod,
    MalformedResponse,
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DecodeError::MalformedLine => write!(f, "malformed request line"),
            DecodeError::UnknownMethod => write!(f, "unknown method"),
            DecodeError::MalformedResponse => write!(f, "malformed response"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// Arbitrary JSON (event `payload`, activity `metadata`, response `result`).
/// Mirrors Swift `JSONValue`; serde_json preserves the int-vs-float distinction
/// so `42` stays `42` and `42.0` stays `42.0`.
pub type Value = serde_json::Value;

// --- line framing (mirrors Swift `LineCodec`) ---

#[derive(Deserialize)]
struct RawRequest {
    method: String,
    params: Value,
}

/// Encode a request to a compact one-line JSON string (no trailing newline).
pub fn encode_request(request: &RequestEnvelope) -> serde_json::Result<String> {
    serde_json::to_string(request)
}

/// Decode a request line. Malformed JSON → `MalformedLine`; an unknown method →
/// `UnknownMethod` (mirrors Swift `LineCodec.decodeRequest`).
pub fn decode_request(line: &str) -> Result<RequestEnvelope, DecodeError> {
    let raw: RawRequest =
        serde_json::from_str(line.trim()).map_err(|_| DecodeError::MalformedLine)?;
    let method = serde_json::from_value::<Method>(Value::String(raw.method.clone()))
        .map_err(|_| DecodeError::UnknownMethod)?;
    Ok(RequestEnvelope { method, params: raw.params })
}

/// Encode a response to a compact one-line JSON string.
pub fn encode_response(response: &ResponseEnvelope) -> serde_json::Result<String> {
    serde_json::to_string(response)
}

/// Decode a response line.
pub fn decode_response(line: &str) -> Result<ResponseEnvelope, DecodeError> {
    serde_json::from_str::<ResponseEnvelope>(line.trim())
        .map_err(|_| DecodeError::MalformedResponse)
}
