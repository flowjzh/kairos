//! CLI command parsing + request building + socket send. Ported from
//! `KairosCLI/CLI.swift`. `--key value` / `--key=value`; `--no-billable` is a
//! bool; `--meta k=v` (repeatable); bare tokens are positional. Time args accept
//! epoch seconds, ISO date/time (local when no offset), or `now`.

use std::collections::BTreeMap;

use kairos_client::{ClientError, Outcome, SocketClient};
use kairos_codec::*;

#[derive(Debug, PartialEq)]
pub struct CliError(pub String);

impl std::fmt::Display for CliError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for CliError {}

impl From<ClientError> for CliError {
    fn from(e: ClientError) -> Self {
        CliError(e.0)
    }
}

#[derive(Default)]
pub struct Flags {
    pub values: BTreeMap<String, String>,
    pub metadata: BTreeMap<String, String>,
    pub positional: Vec<String>,
}

impl Flags {
    pub fn value(&self, key: &str) -> Option<&str> {
        self.values.get(key).map(String::as_str)
    }

    pub fn double(&self, key: &str) -> Option<f64> {
        self.values.get(key).and_then(|s| s.parse().ok())
    }

    pub fn require(&self, key: &str) -> Result<String, CliError> {
        self.values
            .get(key)
            .cloned()
            .ok_or_else(|| CliError(format!("missing required --{key}")))
    }

    pub fn metadata_value(&self) -> Option<BTreeMap<String, Value>> {
        if self.metadata.is_empty() {
            None
        } else {
            Some(self.metadata.iter().map(|(k, v)| (k.clone(), Value::String(v.clone()))).collect())
        }
    }
}

pub fn parse_flags(args: &[String]) -> Flags {
    let mut flags = Flags::default();
    let mut i = 0;
    while i < args.len() {
        let token = &args[i];
        if token == "--no-billable" {
            flags.values.insert("billable".into(), "false".into());
        } else if let Some(rest) = token.strip_prefix("--meta=") {
            apply_meta(rest, &mut flags);
        } else if token == "--meta" && i + 1 < args.len() {
            i += 1;
            apply_meta(&args[i], &mut flags);
        } else if let Some(rest) = token.strip_prefix("--") {
            if let Some(eq) = rest.find('=') {
                let (k, v) = rest.split_at(eq);
                flags.values.insert(k.to_string(), v[1..].to_string());
            } else if i + 1 < args.len() {
                i += 1;
                flags.values.insert(rest.to_string(), args[i].clone());
            }
        } else {
            flags.positional.push(token.clone());
        }
        i += 1;
    }
    flags
}

fn apply_meta(raw: &str, flags: &mut Flags) {
    if let Some(eq) = raw.find('=') {
        let (k, v) = raw.split_at(eq);
        flags.metadata.insert(k.to_string(), v[1..].to_string());
    }
}

/// Parse a time argument: epoch seconds, `now`, or an ISO date/time (local when
/// no offset is given). None if unparseable.
pub fn parse_time(raw: Option<&str>, now: f64) -> Option<f64> {
    let raw = raw?;
    if raw == "now" {
        return Some(now);
    }
    if let Ok(epoch) = raw.parse::<f64>() {
        return Some(epoch);
    }
    parse_iso(raw)
}

fn parse_iso(s: &str) -> Option<f64> {
    use chrono::{DateTime, Local, NaiveDate, NaiveDateTime, TimeZone};
    // Full RFC3339 (with Z or +offset): 2026-07-13T00:00:00Z
    if let Ok(dt) = DateTime::parse_from_rfc3339(s) {
        return Some(dt.timestamp() as f64);
    }
    // Naive datetime, no offset → local: 2026-07-13T00:00:00 | 2026-07-13T00:00
    for fmt in &["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M"] {
        if let Ok(ndt) = NaiveDateTime::parse_from_str(s, fmt) {
            return Local.from_local_datetime(&ndt).single().map(|dt| dt.timestamp() as f64);
        }
    }
    // Date only → local midnight: 2026-07-13
    if let Ok(nd) = NaiveDate::parse_from_str(s, "%Y-%m-%d") {
        let ndt = nd.and_hms_opt(0, 0, 0)?;
        return Local.from_local_datetime(&ndt).single().map(|dt| dt.timestamp() as f64);
    }
    None
}

fn require_time(flags: &Flags, key: &str, now: f64) -> Result<f64, CliError> {
    parse_time(flags.value(key), now).ok_or_else(|| {
        CliError(format!("missing or invalid --{key} (epoch seconds, ISO date/time, or 'now')"))
    })
}

/// Build the wire request for a parsed command. Pure; tested in isolation.
pub fn build_request(
    command: &str,
    subcommand: Option<&str>,
    flags: &Flags,
    now: f64,
) -> Result<RequestEnvelope, CliError> {
    match command {
        "activity" => match subcommand {
            Some("open") => Ok(RequestEnvelope::new(
                Method::ActivitiesOpen,
                serde_json::to_value(ActivitiesOpenParams {
                    source: flags.require("source")?,
                    external_id: flags.value("id").map(str::to_string),
                    project: flags.value("project").map(str::to_string),
                    title: flags.value("title").map(str::to_string),
                    metadata: flags.metadata_value(),
                    kairos_session_id: None,
                })
                .expect("encode"),
            )),
            Some("close") => Ok(RequestEnvelope::new(
                Method::ActivitiesClose,
                serde_json::to_value(ActivitiesCloseParams {
                    source: flags.require("source")?,
                    external_id: flags.value("id").map(str::to_string),
                    ts: flags.double("ts").unwrap_or(now),
                    kairos_session_id: None,
                })
                .expect("encode"),
            )),
            _ => Err(CliError("usage: kairos activity open|close ...".into())),
        },
        "event" => Ok(RequestEnvelope::new(
            Method::EventsPost,
            serde_json::to_value(EventsPostParams {
                activity: Some(ActivityRef {
                    source: flags.require("source")?,
                    external_id: Some(flags.require("id")?),
                }),
                kind: flags.require("kind")?,
                ts: flags.double("ts").unwrap_or(now),
                payload: None,
                kairos_session_id: None,
            })
            .expect("encode"),
        )),
        "pause" => Ok(RequestEnvelope::new(
            Method::ControlPause,
            serde_json::to_value(ControlPauseParams {
                paused: subcommand != Some("off"),
                ts: flags.double("ts").unwrap_or(now),
            })
            .expect("encode"),
        )),
        "owner" => Ok(RequestEnvelope::new(
            Method::ControlOwner,
            serde_json::to_value(ControlOwnerParams {
                source: flags.require("source")?,
                external_id: flags.value("id").map(str::to_string),
                ts: flags.double("ts").unwrap_or(now),
            })
            .expect("encode"),
        )),
        "client" => match subcommand {
            Some("add") => {
                let name = flags
                    .positional
                    .first()
                    .ok_or_else(|| CliError("usage: kairos client add <name>".into()))?;
                Ok(RequestEnvelope::new(
                    Method::ClientsAdd,
                    serde_json::to_value(ClientsAddParams { name: name.clone() }).expect("encode"),
                ))
            }
            Some("rename") => {
                if flags.positional.len() < 2 {
                    return Err(CliError("usage: kairos client rename <id> <name>".into()));
                }
                let id: i64 = flags.positional[0]
                    .parse()
                    .map_err(|_| CliError("usage: kairos client rename <id> <name>".into()))?;
                Ok(RequestEnvelope::new(
                    Method::ClientsRename,
                    serde_json::to_value(ClientsRenameParams { id, name: flags.positional[1].clone() })
                        .expect("encode"),
                ))
            }
            Some("list") => Ok(RequestEnvelope::new(Method::ClientsList, Value::Null)),
            _ => Err(CliError("usage: kairos client add|rename|list ...".into())),
        },
        "map" => match subcommand {
            Some("set") => Ok(RequestEnvelope::new(
                Method::MappingSet,
                serde_json::to_value(MappingSetParams {
                    project: flags.require("project")?,
                    client_id: flags.value("client").and_then(|s| s.parse().ok()),
                    billable: flags.value("billable").map(|s| s != "false").unwrap_or(true),
                })
                .expect("encode"),
            )),
            Some("unset") => Ok(RequestEnvelope::new(
                Method::MappingSet,
                serde_json::to_value(MappingSetParams {
                    project: flags.require("project")?,
                    client_id: None,
                    billable: true,
                })
                .expect("encode"),
            )),
            Some("list") => Ok(RequestEnvelope::new(Method::MappingList, Value::Null)),
            _ => Err(CliError("usage: kairos map set|unset|list ...".into())),
        },
        "export" => {
            let from = require_time(flags, "from", now)?;
            let to = parse_time(flags.value("to"), now).unwrap_or(now);
            Ok(RequestEnvelope::new(
                Method::SegmentsGet,
                serde_json::to_value(SegmentsGetParams {
                    from,
                    to,
                    project: flags.value("project").map(str::to_string),
                    client: flags.value("client").and_then(|s| s.parse().ok()),
                })
                .expect("encode"),
            ))
        }
        _ => Err(CliError(format!("unknown command: {command}"))),
    }
}

/// Entry: build the request, send it, print the result. Ingest commands spool if
/// the daemon is unreachable; reads error out instead.
pub fn run(args: &[String], socket_path: &str, spool_dir: &str) -> Result<(), CliError> {
    let command = args
        .first()
        .map(String::as_str)
        .ok_or_else(|| CliError("usage: kairos <activity|event|client|map|pause|owner|export> ...".into()))?;
    let (subcommand, flag_args) = subcommand_of(command, &args[1..]);
    let flags = parse_flags(flag_args);
    let request = build_request(command, subcommand, &flags, crate::now_secs())?;

    let is_read = command == "export"
        || (command == "client" && subcommand == Some("list"))
        || (command == "map" && subcommand == Some("list"));
    let client = SocketClient::new(socket_path, spool_dir);

    match client.send(&request, !is_read)? {
        Outcome::Spooled => println!("spooled (daemon unreachable)"),
        Outcome::Response(resp) => match resp {
            ResponseEnvelope::Error(e) => return Err(CliError(format!("{}: {}", e.code, e.message))),
            ResponseEnvelope::Result(v) => {
                if is_read {
                    println!("{v}");
                } else if command == "activity" && subcommand == Some("open") {
                    match serde_json::from_value::<ActivitiesOpenResult>(v) {
                        Ok(r) => println!("{}", r.activity_id),
                        Err(_) => println!("ok"),
                    }
                } else {
                    println!("ok");
                }
            }
        },
    }
    Ok(())
}

fn subcommand_of<'a>(command: &str, rest: &'a [String]) -> (Option<&'a str>, &'a [String]) {
    if matches!(command, "activity" | "client" | "map" | "pause") {
        if let Some(first) = rest.first() {
            if !first.starts_with('-') {
                return (Some(first.as_str()), &rest[1..]);
            }
        }
    }
    (None, rest)
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: f64 = 1_000_000.0;

    fn flags(tokens: &[&str]) -> Flags {
        parse_flags(&tokens.iter().map(|s| s.to_string()).collect::<Vec<_>>())
    }

    #[test]
    fn event_builds_events_post() {
        let f = flags(&["--source", "claude-code", "--id", "s1", "--kind", "ai_submit"]);
        let req = build_request("event", None, &f, NOW).unwrap();
        assert_eq!(req.method, Method::EventsPost);
        let p: EventsPostParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.activity.as_ref().unwrap().source, "claude-code");
        assert_eq!(p.activity.as_ref().unwrap().external_id.as_deref(), Some("s1"));
        assert_eq!(p.kind, "ai_submit");
        assert_eq!(p.ts, NOW);
    }

    #[test]
    fn activity_open_builds_request() {
        let f = flags(&["--source", "claude-code", "--id", "s1", "--project", "daemonclaw", "--title", "Build"]);
        let req = build_request("activity", Some("open"), &f, NOW).unwrap();
        assert_eq!(req.method, Method::ActivitiesOpen);
        let p: ActivitiesOpenParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.project.as_deref(), Some("daemonclaw"));
        assert_eq!(p.title.as_deref(), Some("Build"));
    }

    #[test]
    fn client_add_from_positional() {
        let f = flags(&["Acme Corp"]);
        let req = build_request("client", Some("add"), &f, NOW).unwrap();
        assert_eq!(req.method, Method::ClientsAdd);
        let p: ClientsAddParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.name, "Acme Corp");
    }

    #[test]
    fn map_set_with_billable_flag() {
        let f = flags(&["--project", "p1", "--client", "3", "--no-billable"]);
        let req = build_request("map", Some("set"), &f, NOW).unwrap();
        let p: MappingSetParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.project, "p1");
        assert_eq!(p.client_id, Some(3));
        assert!(!p.billable);
    }

    #[test]
    fn export_builds_segments_get() {
        let f = flags(&["--from", "0", "--to", "1000", "--client", "5"]);
        let req = build_request("export", None, &f, NOW).unwrap();
        assert_eq!(req.method, Method::SegmentsGet);
        let p: SegmentsGetParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.from, 0.0);
        assert_eq!(p.to, 1000.0);
        assert_eq!(p.client, Some(5));
    }

    #[test]
    fn export_to_defaults_to_now() {
        let f = flags(&["--from", "0"]);
        let req = build_request("export", None, &f, 5000.0).unwrap();
        let p: SegmentsGetParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.from, 0.0);
        assert_eq!(p.to, 5000.0);
    }

    #[test]
    fn export_accepts_iso_from() {
        let midnight = parse_time(Some("2026-07-13T00:00:00"), 0.0);
        let f = flags(&["--from", "2026-07-13T00:00:00"]);
        let req = build_request("export", None, &f, 0.0).unwrap();
        let p: SegmentsGetParams = serde_json::from_value(req.params).unwrap();
        assert_eq!(p.from, midnight.unwrap());
    }

    #[test]
    fn parse_time_accepts_epoch_now_and_iso() {
        assert_eq!(parse_time(Some("9999999999"), 0.0), Some(9999999999.0));
        assert_eq!(parse_time(Some("now"), 1234.0), Some(1234.0));
        assert!(parse_time(Some("2026-07-13"), 0.0).is_some());
        assert!(parse_time(Some("2026-07-13T12:00:00"), 0.0).is_some());
        assert_eq!(parse_time(Some("not-a-date"), 0.0), None);
    }

    #[test]
    fn pause_defaults_to_on() {
        let req = build_request("pause", Some("on"), &flags(&[]), NOW).unwrap();
        let p: ControlPauseParams = serde_json::from_value(req.params).unwrap();
        assert!(p.paused);
    }

    #[test]
    fn map_unset_emits_tombstone() {
        let f = flags(&["--project", "p1"]);
        let req = build_request("map", Some("unset"), &f, NOW).unwrap();
        let p: MappingSetParams = serde_json::from_value(req.params).unwrap();
        assert!(p.client_id.is_none());
    }

    #[test]
    fn meta_flag_is_repeatable() {
        let f = flags(&["--meta", "a=1", "--meta=b=2"]);
        let m = f.metadata_value().unwrap();
        assert_eq!(m.get("a").and_then(|v| v.as_str()), Some("1"));
        assert_eq!(m.get("b").and_then(|v| v.as_str()), Some("2"));
    }
}
