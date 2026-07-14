//! Transparent PTY passthrough (ported from `kairos-pty`). Runs the command on
//! a pseudo-terminal, injects `KAIROS_SESSION_ID`, taps DECSET-1004 focus on the
//! input stream, and reports each transition to the daemon (best-effort, never
//! spooled) via `focus.report`. Every byte is forwarded unchanged.

use std::io::{Read, Write};
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;

use kairos_client::SocketClient;
use kairos_codec::{FocusReportParams, Method, RequestEnvelope};
use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use signal_hook::consts::SIGWINCH;
use signal_hook::iterator::Signals;

use crate::focus::{Focus, FocusScanner};

fn pty_size() -> PtySize {
    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }
}

/// Run `cmd_args` under a PTY, returning the child's exit code. Focus is live
/// telemetry — best-effort, never spooled (a stale replay against a wiped map is
/// worse than a gap).
pub fn run(cmd_args: &[String], socket_path: &str) -> u8 {
    if cmd_args.is_empty() {
        eprintln!("usage: kairos pty <command> [args...]");
        return 2;
    }
    let session = uuid::Uuid::new_v4().to_string();

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
    // child's PTY line discipline owns echo/signals. Restored on exit.
    let raw_enabled = crossterm::terminal::enable_raw_mode().is_ok();

    // Best-effort focus reporter, decoupled from the byte path by a channel.
    let (tx, rx) = mpsc::channel::<Focus>();
    let reporter = FocusReporter::new(session, PathBuf::from(socket_path));
    thread::spawn(move || {
        for f in rx {
            reporter.report(f);
        }
    });

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

    // Keep the child PTY sized to our terminal.
    if let Ok(mut signals) = Signals::new([SIGWINCH]) {
        thread::spawn(move || {
            for _ in signals.forever() {
                let _ = master.resize(pty_size());
            }
        });
    }

    let status = child.wait();
    if raw_enabled {
        let _ = crossterm::terminal::disable_raw_mode();
    }
    let _ = out.join();
    status.map(|s| s.exit_code() as u8).unwrap_or(1)
}

struct FocusReporter {
    session: String,
    client: SocketClient,
}

impl FocusReporter {
    fn new(session: String, socket: PathBuf) -> Self {
        Self { session, client: SocketClient::new(socket, PathBuf::new()) }
    }

    fn report(&self, focus: Focus) {
        let params = FocusReportParams {
            kairos_session_id: self.session.clone(),
            focused: matches!(focus, Focus::In),
            ts: crate::now_secs(),
        };
        let Ok(value) = serde_json::to_value(&params) else {
            return;
        };
        let req = RequestEnvelope::new(Method::FocusReport, value);
        let _ = self.client.send(&req, false); // best-effort; focus is never spooled
    }
}
