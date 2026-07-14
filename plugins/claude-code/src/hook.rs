//! Maps a Claude Code hook event to a Kairos RPC. This is the *only* Claude
//! Code-specific knowledge in the system — the daemon and `kairos` CLI stay
//! agent-agnostic (ADR 12/20); a different agent ships its own binary with its
//! own mapping. Ported from `KairosClaudeCode/ClaudeCodeHook.swift`.

use std::collections::BTreeMap;

use kairos_codec::*;
use serde::Deserialize;

/// The JSON object Claude Code passes to a hook command on stdin (the subset
/// Kairos needs). Keys per the Claude Code hooks contract.
#[derive(Deserialize)]
pub struct HookInput {
    #[serde(rename = "session_id")]
    pub session_id: String,
    pub cwd: Option<String>,
    #[serde(rename = "transcript_path")]
    pub transcript_path: Option<String>,
    #[serde(rename = "hook_event_name")]
    pub hook_event_name: String,
}

const SOURCE: &str = "claude-code";

/// Map a hook event to a Kairos RPC, or `None` if it isn't one we track (the
/// caller exits 0 regardless — never disrupt Claude). `kairos_session_id` is the
/// wrapping `kairos` PTY session, if any (M4); it rides on every RPC so the
/// daemon can keep its focus map fresh. Encode failures also yield `None`.
pub fn request(input: &HookInput, kairos_session_id: Option<&str>, now: f64) -> Option<RequestEnvelope> {
    let activity = ActivityRef {
        source: SOURCE.into(),
        external_id: Some(input.session_id.clone()),
    };
    let kid = kairos_session_id.map(str::to_string);
    match input.hook_event_name.as_str() {
        "SessionStart" => {
            let project = input.cwd.as_ref().map(|c| basename(c));
            let mut metadata: BTreeMap<String, Value> = BTreeMap::new();
            if let Some(path) = &input.transcript_path {
                metadata.insert("transcript_path".into(), Value::String(path.clone()));
            }
            if let Some(cwd) = &input.cwd {
                metadata.insert("cwd".into(), Value::String(cwd.clone()));
            }
            let params = ActivitiesStartParams {
                source: SOURCE.into(),
                external_id: Some(input.session_id.clone()),
                project,
                title: None,
                metadata: if metadata.is_empty() { None } else { Some(metadata) },
                kairos_session_id: kid,
                afk_immune: None,
                // The plugin owns its source label. TODO(i18n): translate.
                source_display_name: Some("Claude Code".into()),
            };
            Some(RequestEnvelope::new(Method::ActivitiesStart, serde_json::to_value(&params).ok()?))
        }
        "UserPromptSubmit" => event(&activity, "ai_submit", kid, now),
        "Stop" => event(&activity, "ai_stop", kid, now),
        "SessionEnd" => {
            let params = ActivitiesStopParams {
                source: Some(SOURCE.into()),
                external_id: Some(input.session_id.clone()),
                kairos_session_id: kid,
                ts: now,
            };
            Some(RequestEnvelope::new(Method::ActivitiesStop, serde_json::to_value(&params).ok()?))
        }
        _ => None,
    }
}

/// Build a `notify.user` request iff this is an unwrapped `SessionStart` — the
/// agent launched directly, not under `kairos`, so focus/blur timing is missing.
/// The plugin owns the decision and the wording; the daemon only delivers (and
/// cooldown-gates) it. `None` for every other event, or when a kid is present.
pub fn notify_unwrapped(event: &str, kairos_session_id: Option<&str>) -> Option<RequestEnvelope> {
    if event != "SessionStart" || kairos_session_id.is_some() {
        return None;
    }
    let params = NotifyUserParams {
        source: SOURCE.into(),
        kind: "pty_recommended".into(),
        title: "Focus Tracking Off".into(),
        subtitle: None,
        message: "Claude Code started directly — relaunch via kairos to capture focus/blur.".into(),
        // No cooldown: a nudge on every unwrapped start, not once per hour.
        cooldown_seconds: None,
    };
    Some(RequestEnvelope::new(Method::NotifyUser, serde_json::to_value(&params).ok()?))
}

fn event(activity: &ActivityRef, kind: &str, kid: Option<String>, now: f64) -> Option<RequestEnvelope> {
    let params = EventsPostParams {
        activity: Some(activity.clone()),
        kind: kind.into(),
        ts: now,
        payload: None,
        kairos_session_id: kid,
    };
    Some(RequestEnvelope::new(Method::EventsPost, serde_json::to_value(&params).ok()?))
}

fn basename(path: &str) -> String {
    std::path::Path::new(path)
        .file_name()
        .and_then(|n| n.to_str())
        .map(str::to_string)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(event: &str, cwd: Option<&str>, transcript: Option<&str>) -> HookInput {
        HookInput {
            session_id: "sess-1".into(),
            cwd: cwd.map(str::to_string),
            transcript_path: transcript.map(str::to_string),
            hook_event_name: event.into(),
        }
    }

    fn default_input(event: &str) -> HookInput {
        input(event, Some("/Users/me/Desktop/daemonclaw"), Some("/tmp/t.jsonl"))
    }

    #[test]
    fn session_start_opens_activity_with_project_from_cwd() {
        let req = request(&default_input("SessionStart"), None, 100.0).unwrap();
        assert_eq!(req.method, Method::ActivitiesStart);
        let p: ActivitiesStartParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.source, "claude-code");
        assert_eq!(p.external_id.as_deref(), Some("sess-1"));
        assert_eq!(p.project.as_deref(), Some("daemonclaw"));
        assert_eq!(p.metadata.as_ref().unwrap().get("transcript_path").and_then(|v| v.as_str()), Some("/tmp/t.jsonl"));
        assert_eq!(p.metadata.as_ref().unwrap().get("cwd").and_then(|v| v.as_str()), Some("/Users/me/Desktop/daemonclaw"));
    }

    #[test]
    fn user_prompt_submit_posts_ai_submit() {
        let req = request(&default_input("UserPromptSubmit"), None, 250.0).unwrap();
        assert_eq!(req.method, Method::EventsPost);
        let p: EventsPostParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.kind, "ai_submit");
        assert_eq!(p.ts, 250.0);
        assert_eq!(p.activity.unwrap().external_id.unwrap(), "sess-1");
    }

    #[test]
    fn stop_posts_ai_stop() {
        let req = request(&default_input("Stop"), None, 300.0).unwrap();
        let p: EventsPostParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.kind, "ai_stop");
    }

    #[test]
    fn session_end_closes_activity() {
        let req = request(&default_input("SessionEnd"), None, 400.0).unwrap();
        assert_eq!(req.method, Method::ActivitiesStop);
        let p: ActivitiesStopParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.external_id.as_deref(), Some("sess-1"));
        assert_eq!(p.ts, 400.0);
    }

    #[test]
    fn unknown_event_is_ignored() {
        assert!(request(&default_input("PreToolUse"), None, 0.0).is_none());
    }

    #[test]
    fn malformed_json_is_ignored() {
        assert!(serde_json::from_slice::<HookInput>(b"not json").is_err());
    }

    #[test]
    fn decodes_real_hook_json() {
        let json = br#"{"session_id":"abc","cwd":"/w/proj","transcript_path":"/t.jsonl","hook_event_name":"Stop"}"#;
        let input = serde_json::from_slice::<HookInput>(json).unwrap();
        let req = request(&input, None, 5.0).unwrap();
        assert_eq!(req.method, Method::EventsPost);
    }

    #[test]
    fn session_start_without_cwd_has_no_project() {
        let req = request(&input("SessionStart", None, None), None, 1.0).unwrap();
        let p: ActivitiesStartParams = serde_json::from_value(req.params).unwrap();
        assert!(p.project.is_none());
        assert!(p.metadata.is_none());
    }

    #[test]
    fn kairos_session_id_rides_on_every_rpc() {
        let kid = "kpty-xyz";
        let open = request(&default_input("SessionStart"), Some(kid), 1.0).unwrap();
        assert_eq!(
            serde_json::from_value::<ActivitiesStartParams>(open.params).unwrap().kairos_session_id.as_deref(),
            Some(kid)
        );
        let submit = request(&default_input("UserPromptSubmit"), Some(kid), 1.0).unwrap();
        assert_eq!(
            serde_json::from_value::<EventsPostParams>(submit.params).unwrap().kairos_session_id.as_deref(),
            Some(kid)
        );
        let end = request(&default_input("SessionEnd"), Some(kid), 1.0).unwrap();
        assert_eq!(
            serde_json::from_value::<ActivitiesStopParams>(end.params).unwrap().kairos_session_id.as_deref(),
            Some(kid)
        );
    }

    #[test]
    fn kairos_session_id_absent_when_unwrapped() {
        let open = request(&default_input("SessionStart"), None, 1.0).unwrap();
        assert!(serde_json::from_value::<ActivitiesStartParams>(open.params).unwrap().kairos_session_id.is_none());
    }

    #[test]
    fn kairos_session_id_encodes_snake_case() {
        let submit = request(&default_input("UserPromptSubmit"), Some("k1"), 1.0).unwrap();
        let json = serde_json::to_string(&submit.params).unwrap();
        assert!(json.contains("kairos_session_id"));
    }

    #[test]
    fn notify_unwrapped_only_when_session_start_without_kid() {
        let notify = notify_unwrapped("SessionStart", None).unwrap();
        assert_eq!(notify.method, Method::NotifyUser);
        let p: NotifyUserParams = serde_json::from_value(notify.params).unwrap();
        assert_eq!(p.source, "claude-code");
        assert_eq!(p.kind, "pty_recommended");
        assert_eq!(p.title, "Focus Tracking Off");
        assert!(p.subtitle.is_none());
        assert!(p.message.contains("focus/blur"));
    }

    #[test]
    fn notify_unwrapped_none_when_kid_present() {
        assert!(notify_unwrapped("SessionStart", Some("k1")).is_none());
    }

    #[test]
    fn notify_unwrapped_none_for_other_events() {
        assert!(notify_unwrapped("UserPromptSubmit", None).is_none());
        assert!(notify_unwrapped("Stop", None).is_none());
        assert!(notify_unwrapped("SessionEnd", None).is_none());
    }
}
