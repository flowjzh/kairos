//! `kairos-pty <command> [args...]` — a transparent PTY wrapper. It runs the
//! command (e.g. `claude`) on a pseudo-terminal, injects `KAIROS_SESSION_ID`
//! into its environment, and copies bytes both ways unchanged. On the input
//! path it taps DECSET-1004 focus events and reports each to the Kairos daemon,
//! so the daemon can attribute focus/blur to the wrapped AI session (M4).

mod focus;
mod report;

use std::io::{Read, Write};
use std::sync::mpsc;
use std::thread;

use portable_pty::{native_pty_system, CommandBuilder, PtySize};
use signal_hook::consts::SIGWINCH;
use signal_hook::iterator::Signals;

use focus::FocusScanner;
use report::Reporter;

fn pty_size() -> PtySize {
    let (cols, rows) = crossterm::terminal::size().unwrap_or((80, 24));
    PtySize { rows, cols, pixel_width: 0, pixel_height: 0 }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() {
        eprintln!("usage: kairos-pty <command> [args...]");
        std::process::exit(2);
    }

    let session = uuid::Uuid::new_v4().to_string();

    let pair = native_pty_system()
        .openpty(pty_size())
        .expect("kairos-pty: openpty failed");

    let mut cmd = CommandBuilder::new(&args[0]);
    for a in &args[1..] {
        cmd.arg(a);
    }
    cmd.env("KAIROS_SESSION_ID", &session);
    // portable-pty defaults the child's cwd to $HOME; inherit ours instead so
    // the child (and its project attribution) sees the real launch directory.
    if let Ok(cwd) = std::env::current_dir() {
        cmd.cwd(cwd);
    }

    let mut child = pair
        .slave
        .spawn_command(cmd)
        .expect("kairos-pty: failed to spawn command");
    drop(pair.slave); // the parent keeps only the master side

    let mut writer = pair.master.take_writer().expect("pty writer");
    let mut reader = pair.master.try_clone_reader().expect("pty reader");
    let master = pair.master;

    // Raw mode on our own terminal, so keystrokes pass through untouched and the
    // child's PTY line discipline (not ours) owns echo/signals. Restored on exit.
    let raw_enabled = crossterm::terminal::enable_raw_mode().is_ok();

    // Best-effort focus reporter, decoupled from the byte path by a channel.
    let (tx, rx) = mpsc::channel::<focus::Focus>();
    let reporter = Reporter::new(session);
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
    let code = status.map(|s| s.exit_code() as i32).unwrap_or(1);
    std::process::exit(code);
}
