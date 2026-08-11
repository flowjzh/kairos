//! Typed response results. Mirrors `KairosRPC/Results.swift`. Maps use
//! `BTreeMap` so emitted keys are sorted (matches Swift's `.sortedKeys`).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::Value;

/// An empty `{"result":{}}`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EmptyResult {}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesStartResult {
    pub activity_id: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientEntry {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientsListResult {
    pub clients: Vec<ClientEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClientsAddResult {
    pub id: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MappingEntry {
    pub project: String,
    pub client_id: Option<i64>,
    pub billable: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MappingListResult {
    pub map: Vec<MappingEntry>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WireSegment {
    pub activity_id: i64,
    pub start: f64,
    pub end: f64,
    pub seconds: f64,
    pub rule: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WireClient {
    pub id: i64,
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct WireActivity {
    pub source: String,
    pub external_id: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
    pub client: Option<WireClient>,
    pub billable: bool,
    pub metadata: Option<BTreeMap<String, Value>>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SegmentsGetResult {
    pub segments: Vec<WireSegment>,
    pub activities: BTreeMap<String, WireActivity>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusedActivity {
    pub source: String,
    pub external_id: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusedGetResult {
    pub activity: Option<FocusedActivity>,
}

/// One statusline field: a localized visible `label`, the `text` to show (None
/// when the field has no value, e.g. an activity with no title), and an optional
/// stable color key the client maps to ANSI.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityStatusField {
    pub label: String,
    pub text: Option<String>,
    pub color: Option<String>,
}

/// `activities.status` result — a flat dict whose keys are either the four
/// normal fields (`activity`/`state`/`total`/`today`) or a single `error` field,
/// never both (a producer contract enforced in the daemon handler). Each `Option`
/// field is omitted when `None`, yielding exactly that shape on the wire
/// (per-field `skip_serializing_if` — portable across serde versions).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivityStatusResult {
    /// The activity's display name (title ?? project), resolved daemon-side so
    /// the renderer needs no fallback logic. Labeled "Activity"/"活动".
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub activity: Option<ActivityStatusField>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub state: Option<ActivityStatusField>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub total: Option<ActivityStatusField>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub today: Option<ActivityStatusField>,
    #[serde(skip_serializing_if = "Option::is_none", default)]
    pub error: Option<ActivityStatusField>,
}
