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

/// Run `cmd_args` under a PTY, returning the child's exit code. An optional
/// leading `--project <slug>` associates the pty activity with that project
/// (looked up / auto-registered by slug); with no `--project` the activity has
/// no project and the menu shows the command instead.
pub fn run(raw_args: &[String], socket_path: &str) -> u8 {
    let (project, cmd_args): (Option<String>, &[String]) =
        if raw_args.first().map(String::as_str) == Some("--project") {
            (raw_args.get(1).cloned(), raw_args.get(2..).unwrap_or(&[]))
        } else {
            (None, raw_args)
        };
    if cmd_args.is_empty() {
        eprintln!("usage: kairos [--project <slug>] <command> [args...]");
        return 2;
    }
    let session = uuid::Uuid::new_v4().to_string();
    let title = cmd_args.join(" ");

    let pair = native_pty_system()
        .openpty(pty_size())
        .expect("kairos: openpty failed");

    let mut cmd = CommandBuilder::new(&cmd_args[0]);
    for a in &cmd_args[1..] {
        cmd.arg(a);
    }
    cmd.env("KAIROS_SESSION_ID", &session);
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
        let title = title.clone();
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
