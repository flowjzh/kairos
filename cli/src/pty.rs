//! Transparent PTY passthrough. Runs the command on a pseudo-terminal, injects
//! `KAIROS_SESSION_ID` (kid), taps DECSET-1004 focus on the input stream, and
//! drives the activity's lifecycle (M4p3, Design B): a launch `focus`, a 5 s
//! `activities.ensure` (creates a `pty` activity iff no hook claimed the kid —
//! covers `vim`/`ssh`), and an exit `activities.stop`. Every byte is forwarded
//! unchanged; all daemon calls are best-effort (never spooled).

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use kairos_client::SocketClient;
use kairos_codec::{
    ActivitiesEnsureParams, ActivitiesStopParams, FocusReportParams, Method, RequestEnvelope,
};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use signal_hook::consts::{SIGHUP, SIGINT, SIGTERM, SIGWINCH};
use signal_hook::iterator::Signals;

use crate::focus::{Focus, FocusScanner};

/// Built-in source for wrapped non-agent commands (agents enrich this later).
const PTY_SOURCE: &str = "pty";
/// Delay before the wrapper claims the kid, giving an agent's SessionStart hook
/// time to create the activity first (probed reliable). Sub-5 s commands create
/// no activity — trivial commands stay off the timesheet.
const ENSURE_DELAY: Duration = Duration::from_secs(5);

fn pty_size() -> PtySize {
    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }
}

/// Split leading `--title <title>` / `--project <slug>` pairs (in any order)
/// from the command and its args. The first non-flag token begins `cmd_args`,
/// so `vim --title foo` hands `--title foo` through to vim. Returns the title
/// and project only when their flag is present (None otherwise) — callers treat
/// "absent" and "default" differently (the env passthrough fires only on an
/// explicit `--title`, so `kairos claude` without it keeps title unset).
fn split_flags(raw: &[String]) -> (Option<String>, Option<String>, &[String]) {
    let mut title = None;
    let mut project = None;
    let mut i = 0;
    while i + 1 < raw.len() {
        match raw[i].as_str() {
            "--title" => title = Some(raw[i + 1].clone()),
            "--project" => project = Some(raw[i + 1].clone()),
            _ => break,
        }
        i += 2;
    }
    (title, project, &raw[i..])
}

/// Run `cmd_args` under a PTY, returning the child's exit code. Optional leading
/// `--title <title>` / `--project <slug>` (any order) name the activity and tag
/// its project; with neither, the pty activity has no title/project and the menu
/// shows the command instead.
pub fn run(raw_args: &[String], socket_path: &str) -> u8 {
    let (title_flag, project, cmd_args) = split_flags(raw_args);
    if cmd_args.is_empty() {
        eprintln!("usage: kairos [--title <title>] [--project <slug>] <command> [args...]");
        return 2;
    }
    let session = uuid::Uuid::new_v4().to_string();
    // The pty activity's own title (shown when no agent hook claims the kid):
    // the explicit `--title` if given, else the command string as before.
    let pty_title = title_flag.clone().unwrap_or_else(|| cmd_args.join(" "));

    let pair = native_pty_system()
        .openpty(pty_size())
        .expect("kairos: openpty failed");

    let mut cmd = CommandBuilder::new(&cmd_args[0]);
    for a in &cmd_args[1..] {
        cmd.arg(a);
    }
    cmd.env("KAIROS_SESSION_ID", &session);
    // Only signal an explicit title: `kairos claude` (no `--title`) must leave
    // this unset so the CC plugin keeps title None (its current behavior),
    // rather than adopting the command string as a title.
    if let Some(t) = &title_flag {
        cmd.env("KAIROS_ACTIVITY_TITLE", t);
    }
    // portable-pty defaults the child's cwd to $HOME; inherit ours so the child
    // (and its project attribution) sees the real launch directory.
    if let Ok(cwd) = std::env::current_dir() {
        cmd.cwd(cwd);
    }

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .expect("kairos: failed to spawn command");
    drop(pair.slave); // the parent keeps only the master side

    let mut writer = pair.master.take_writer().expect("pty writer");
    let mut reader = pair.master.try_clone_reader().expect("pty reader");
    let master = pair.master;

    // Raw mode on our own terminal, so keystrokes pass through untouched and the
    // child's PTY line discipline owns echo/signals. `disable_raw_mode` is
    // idempotent, so we restore unconditionally on every exit path.
    let _ = crossterm::terminal::enable_raw_mode();

    let reporter = Arc::new(Reporter::new(session.clone(), socket_path));
    // Launch focus: the split is focused (you just ran the command). Buffered by
    // the daemon until the activity exists, then back-dated to now — so vim/ssh
    // count from t0 even though DECSET-1004 reports no initial focus.
    reporter.focus(true);
    // After the delay, create a `pty` activity iff no hook claimed the kid.
    {
        let reporter = Reporter::new(session.clone(), socket_path);
        let project = project.clone();
        let title = pty_title.clone();
        thread::spawn(move || {
            thread::sleep(ENSURE_DELAY);
            reporter.ensure(project.as_deref(), &title);
        });
    }

    // Best-effort focus reporter, decoupled from the byte path by a channel.
    let (tx, rx) = mpsc::channel::<Focus>();
    {
        let reporter = Reporter::new(session.clone(), socket_path);
        thread::spawn(move || {
            for f in rx {
                reporter.focus(matches!(f, Focus::In));
            }
        });
    }

    // stdin (our terminal) -> child, tapping focus on the way.
    thread::spawn(move || {
        let mut scanner = FocusScanner::default();
        let mut stdin = std::io::stdin();
        let mut buf = [0u8; 4096];
        loop {
            match stdin.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    for f in scanner.feed(&buf[..n]) {
                        let _ = tx.send(f);
                    }
                    if writer.write_all(&buf[..n]).is_err() || writer.flush().is_err() {
                        break;
                    }
                }
            }
        }
    });

    // child -> stdout (our terminal).
    let out = thread::spawn(move || {
        let mut stdout = std::io::stdout();
        let mut buf = [0u8; 4096];
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if stdout.write_all(&buf[..n]).is_err() || stdout.flush().is_err() {
                        break;
                    }
                }
            }
        }
    });

    // One signal thread: SIGWINCH keeps the child PTY sized to our terminal;
    // a terminating signal (Ctrl-C / term / hangup) runs the *same* teardown as
    // the normal exit below — restore the terminal, then report stop — before
    // the process is killed. Otherwise the activity stays active and the
    // terminal is left in raw mode (the exit cleanup never runs on a signal).
    // The child shares our foreground process group, so the signal reaches it
    // directly; we only need our own cleanup.
    {
        let reporter = Arc::clone(&reporter);
        thread::spawn(move || {
            let mut signals = match Signals::new([SIGWINCH, SIGINT, SIGTERM, SIGHUP]) {
                Ok(s) => s,
                Err(_) => return,
            };
            for sig in signals.forever() {
                if sig == SIGWINCH {
                    let _ = master.resize(pty_size());
                } else {
                    let _ = crossterm::terminal::disable_raw_mode();
                    reporter.stop();
                    std::process::exit(128 + sig as i32);
                }
            }
        });
    }

    let status = child.wait();
    let _ = crossterm::terminal::disable_raw_mode();
    let _ = out.join();
    reporter.stop(); // exit → blur + state=stopped (by kid)
    status.map(|s| s.exit_code() as u8).unwrap_or(1)
}

/// Best-effort daemon client for one wrapper session (keyed by kid). Never
/// spooled — focus/lifecycle are live telemetry; a stale replay is worse.
struct Reporter {
    session: String,
    client: SocketClient,
}

impl Reporter {
    fn new(session: String, socket: &str) -> Self {
        Self { session, client: SocketClient::new(PathBuf::from(socket), PathBuf::new()) }
    }

    fn send(&self, method: Method, value: serde_json::Value) {
        let _ = self.client.send(&RequestEnvelope::new(method, value), false);
    }

    fn focus(&self, focused: bool) {
        let params = FocusReportParams {
            kairos_session_id: self.session.clone(),
            focused,
            ts: crate::now_secs(),
        };
        if let Ok(value) = serde_json::to_value(&params) {
            self.send(Method::FocusReport, value);
        }
    }

    fn ensure(&self, project: Option<&str>, title: &str) {
        let params = ActivitiesEnsureParams {
            kairos_session_id: self.session.clone(),
            source: PTY_SOURCE.to_string(),
            project: project.map(str::to_string),
            title: Some(title.to_string()),
            ts: crate::now_secs(),
        };
        if let Ok(value) = serde_json::to_value(&params) {
            self.send(Method::ActivitiesEnsure, value);
        }
    }

    fn stop(&self) {
        // Resolve by the kid (the daemon's in-memory map). A pty activity has no
        // external_id, so there is no restart-proof fallback — a daemon restart
        // mid-session may orphan it (rare; the kid map is ephemeral by design).
        let params = ActivitiesStopParams {
            source: None,
            external_id: None,
            kairos_session_id: Some(self.session.clone()),
            ts: crate::now_secs(),
        };
        if let Ok(value) = serde_json::to_value(&params) {
            self.send(Method::ActivitiesStop, value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::split_flags;

    fn owned(items: &[&str]) -> Vec<String> {
        items.iter().map(|s| (*s).to_string()).collect()
    }

    #[test]
    fn title_only() {
        let raw = owned(&["--title", "Foo", "vim"]);
        let (title, project, cmd) = split_flags(&raw);
        assert_eq!(title.as_deref(), Some("Foo"));
        assert!(project.is_none());
        assert_eq!(cmd, ["vim"]);
    }

    #[test]
    fn title_and_project_compose_in_either_order() {
        let cases = [
            owned(&["--title", "Foo", "--project", "bar", "claude"]),
            owned(&["--project", "bar", "--title", "Foo", "claude"]),
        ];
        for raw in cases {
            let (title, project, cmd) = split_flags(&raw);
            assert_eq!(title.as_deref(), Some("Foo"), "{raw:?}");
            assert_eq!(project.as_deref(), Some("bar"), "{raw:?}");
            assert_eq!(cmd, ["claude"], "{raw:?}");
        }
    }

    #[test]
    fn flags_after_command_pass_through() {
        // `vim --title foo` — the flag belongs to vim, not kairos.
        let raw = owned(&["vim", "--title", "foo"]);
        let (title, project, cmd) = split_flags(&raw);
        assert!(title.is_none());
        assert!(project.is_none());
        assert_eq!(cmd, ["vim", "--title", "foo"]);
    }

    #[test]
    fn title_without_command_is_empty() {
        let raw = owned(&["--title", "Foo"]);
        let (_title, _project, cmd) = split_flags(&raw);
        assert!(cmd.is_empty());
    }

    #[test]
    fn no_flags_passes_all_through() {
        let raw = owned(&["claude", "--resume"]);
        let (title, project, cmd) = split_flags(&raw);
        assert!(title.is_none());
        assert!(project.is_none());
        assert_eq!(cmd, ["claude", "--resume"]);
    }
}
