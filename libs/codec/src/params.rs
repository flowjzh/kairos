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
pub struct ActivitiesStartParams {
    pub source: String,
    pub external_id: Option<String>,
    pub project: Option<String>,
    pub title: Option<String>,
    pub metadata: Option<BTreeMap<String, Value>>,
    /// The wrapping `kairos` PTY session, when launched under one — routes this
    /// activity's focus reports by kid (M4).
    pub kairos_session_id: Option<String>,
    /// Explicit activities may disable AFK detection while focused (M4p3).
    pub afk_immune: Option<bool>,
    /// Human-facing name for this source (the plugin owns its label); recorded on
    /// `sources.display_name`.
    pub source_display_name: Option<String>,
}

/// Stop (→ state=stopped). Resolvable by `(source, external_id)` (hook / menu) or
/// by `kairos_session_id` (the wrapper's exit).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesStopParams {
    pub source: Option<String>,
    pub external_id: Option<String>,
    pub kairos_session_id: Option<String>,
    pub ts: f64,
}

/// The wrapper's ~5 s post-launch call: create a `pty` activity only if the kid
/// is still unclaimed by a hook (Design B, M4p3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesEnsureParams {
    pub kairos_session_id: String,
    pub source: String,
    pub project: Option<String>,
    pub title: Option<String>,
    pub ts: f64,
}

/// `activities.status` — per-session statusline payload for one activity,
/// addressed by its `(source, external_id)` identity.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ActivitiesStatusParams {
    pub source: String,
    pub external_id: String,
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

/// A plugin's request to nudge the user with a native notification (e.g. the
/// agent launched without `kairos`, so focus/blur is missing). The plugin owns
/// the decision and the wording; the daemon only delivers and cooldown-gates by
/// `(source, kind)`. Mirrors `KairosRPC.NotifyUserParams`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NotifyUserParams {
    pub source: String,
    pub kind: String,
    pub title: String,
    /// Optional secondary line under the title (rendered smaller). Used to put
    /// the exact command on its own line (e.g. "kairos claude") — the platform
    /// has no inline code/monospace style, so a separate line is the only way to
    /// set it apart.
    pub subtitle: Option<String>,
    pub message: String,
    /// If set, the daemon delivers at most once per this many seconds per
    /// `(source, kind)`; if `None`, every call is delivered. Omitted by the
    /// claude-code plugin (a nudge on every unwrapped start, not once/hour).
    pub cooldown_seconds: Option<f64>,
}

/// Manual focus switch from the menu (→ a `focus` event); replaces the removed
/// `force_owner` (M4p3).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FocusSetParams {
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
