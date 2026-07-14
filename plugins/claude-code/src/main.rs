//! Claude Code hook binary. Reads the hook JSON from stdin, maps it to a Kairos
//! RPC, and sends it over the socket (spooling if the daemon is down). Always
//! exits 0 — a time-tracking hook must never disrupt the editor.
//
// Wired for all four events in the plugin's hooks.json; the event is read from
// the stdin `hook_event_name`, so one command serves them all.

mod hook;

use std::io::Read;
use std::time::{SystemTime, UNIX_EPOCH};

use kairos_client::SocketClient;

fn main() {
    let code = run();
    std::process::exit(code);
}

fn run() -> i32 {
    let socket = kairos_client::default_socket_path();
    let spool = kairos_client::default_spool_dir();

    let mut data = Vec::new();
    let _ = std::io::stdin().read_to_end(&mut data);

    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    let kid = std::env::var("KAIROS_SESSION_ID").ok().filter(|s| !s.is_empty());

    // Malformed JSON or an untracked event → ignore silently (exit 0).
    let Some(input) = serde_json::from_slice::<hook::HookInput>(&data).ok() else {
        return 0;
    };

    let client = SocketClient::new(&socket, &spool);

    // The activity RPC: spool it if the daemon is down — it's real data.
    if let Some(request) = hook::request(&input, kid.as_deref(), now) {
        let _ = client.send(&request, true);
    }

    // A transient nudge when the agent started without `kairos` — never spooled,
    // since a stale "launch via kairos" reminder long after the fact is noise.
    if let Some(notify) = hook::notify_unwrapped(&input.hook_event_name, kid.as_deref()) {
        let _ = client.send(&notify, false);
    }
    0
}
