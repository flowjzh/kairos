//! Typed request params. Field names are snake_case (Rust idiom = wire shape, so
//! no `rename_all` is needed). Optional fields are omitted when `None`, matching
//! Swift's nil-omitting `Codable`. Mirrors `KairosRPC/Params.swift`.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::Value;

/// `{source, external_id}` — identifies an activity (slugs/strings).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityRef {
    pub source: String,
    pub external_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesOpenParams {
    pub source: String,
    pub external_id: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
    pub metadata: Option<BTreeMap<String, Value>>,
    /// The wrapping `kairos` PTY session, when launched under one — lets the
    /// daemon map this activity's `external_id` to focus reports (M4).
    pub kairos_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesCloseParams {
    pub source: String,
    pub external_id: Option<String>,
    pub ts: f64,
    pub kairos_session_id: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EventsPostParams {
    pub activity: Option<ActivityRef>,
    pub kind: String,
    pub ts: f64,
    pub payload: Option<Value>,
    pub kairos_session_id: Option<String>,
}

/// A terminal focus transition from the `kairos` PTY wrapper, keyed by the
/// wrapper session. The daemon resolves `kairos_session_id` to an activity (via
/// the hook-populated map) and appends `focus`/`blur` (M4; renamed from
/// `ai_focus`/`ai_blur`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusReportParams {
    pub kairos_session_id: String,
    pub focused: bool,
    pub ts: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlPauseParams {
    pub paused: bool,
    pub ts: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ControlOwnerParams {
    pub source: String,
    pub external_id: Option<String>,
    pub ts: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientsAddParams {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientsRenameParams {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MappingSetParams {
    pub project: String,
    pub client_id: Option<i64>,
    pub billable: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SegmentsGetParams {
    pub from: f64,
    pub to: f64,
    pub project: Option<String>,
    pub client: Option<i64>,
}
