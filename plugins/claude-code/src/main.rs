//! Claude Code hook binary. Two modes, dispatched by argv[1]:
//!
//! - `kairos-claude-code` (no arg, as invoked by `hooks.json`): reads the hook
//!   JSON from stdin, maps it to a Kairos RPC, sends it over the socket (spooling
//!   if the daemon is down). Always exits 0 — a time-tracking hook must never
//!   disrupt the editor.
//! - `kairos-claude-code statusline`: the CC status line command. Reads the
//!   statusline JSON from stdin, pulls `session_id`, queries `activities.status`,
//!   and prints one colored line. Also exits 0 even on daemon-down (prints an
//!   in-line error instead) so the status line never breaks the TUI.
//
// The hook mode is wired for all events in hooks.json; the event is read from
// the stdin `hook_event_name`, so one command serves them all.

mod hook;

use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

use kairos_client::{Outcome, SocketClient};
use kairos_codec::{ActivitiesStatusParams, Method, RequestEnvelope, ResponseEnvelope};

fn main() {
    let code = run();
    std::process::exit(code);
}

fn run() -> i32 {
    // `hooks.json` invokes with no argv; `statusline` is the one subcommand.
    if std::env::args().nth(1).as_deref() == Some("statusline") {
        return statusline();
    }
    hook_mode()
}

/// The hook → RPC forwarder (the original mode).
fn hook_mode() -> i32 {
    let socket = kairos_client::default_socket_path();
    let spool = kairos_client::default_spool_dir();

    let mut data = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut data);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let kid = std::env::var("KAIROS_SESSION_ID").ok().filter(|s| !s.is_empty());
    // Empty/whitespace title normalization lives in `hook::request` (trim then
    // filter) — no need to pre-filter here (unlike `kid`, which hook.rs doesn't).
    let title = std::env::var("KAIROS_ACTIVITY_TITLE").ok();

    // Malformed JSON or an untracked event → ignore silently (exit 0).
    let Some(input) = serde_json::from_slice::<hook::HookInput>(&data).ok() else {
        return 0;
    };

    let client = SocketClient::new(&socket, &spool);

    // The activity RPC: spool it if the daemon is down — it's real data.
    if let Some(request) = hook::request(&input, kid.as_deref(), title.as_deref(), now) {
        let _ = client.send(&request, true);
    }

    // A transient nudge when the agent started without `kairos` — never spooled,
    // since a stale "launch via kairos" reminder long after the fact is noise.
    if let Some(notify) = hook::notify_unwrapped(&input.hook_event_name, kid.as_deref()) {
        let _ = client.send(&notify, false);
    }
    0
}

/// The status line command: render one colored line for the current session.
fn statusline() -> i32 {
    let mut data = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut data);

    // The CC statusline JSON carries `session_id` (the same id the hook uses as
    // external_id). Deserialize just that field — serde ignores the rest, so the
    // full payload (model, workspace, cost, …) never materializes as a DOM.
    #[derive(serde::Deserialize)]
    struct StatusLineInput {
        #[serde(rename = "session_id")]
        session_id: Option<String>,
    }
    let session_id = serde_json::from_slice::<StatusLineInput>(&data)
        .ok()
        .and_then(|i| i.session_id.filter(|s| !s.is_empty()));
    let Some(session_id) = session_id else {
        // No session id → nothing to show. An empty line keeps the TUI clean.
        return 0;
    };

    let socket = kairos_client::default_socket_path();
    let spool = kairos_client::default_spool_dir();
    let client = SocketClient::new(&socket, &spool);

    let params = ActivitiesStatusParams {
        source: hook::SOURCE.into(),
        external_id: session_id,
    };
    let request = match serde_json::to_value(&params) {
        Ok(p) => RequestEnvelope::new(Method::ActivitiesStatus, p),
        Err(_) => return 0,
    };

    // Reads are never spooled — a stale statusline replay is meaningless. Daemon
    // unreachable (Err, or Spooled which can't happen here) → in-line red error;
    // a broken status line is worse than an honest "can't reach Kairos".
    if let Ok(Outcome::Response(ResponseEnvelope::Result(v))) = client.send(&request, false) {
        if let Ok(result) = serde_json::from_value::<kairos_codec::ActivityStatusResult>(v) {
            print!("{}", kairos_statusline::render(&result));
        }
    } else {
        print!("\x1b[31mError: cannot connect to Kairos\x1b[0m");
    }
    0
}
