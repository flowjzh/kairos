//! `kairos` — CLI + transparent PTY wrapper. Known subcommands speak the
//! line-JSON RPC to the daemon; any other command runs under a PTY
//! (`kairos claude`) so its terminal focus can be attributed. Fallback: a bare
//! word that resolves on PATH (or is a `/`-path) is wrapped; one that doesn't is
//! a likely typo → error + suggestion.

mod cli;
mod focus;
mod pty;

use std::path::Path;
use std::process::ExitCode;

const KNOWN_SUBCOMMANDS: &[&str] =
    &["activity", "event", "client", "map", "pause", "focus", "export"];

/// Reserved non-subcommand words (also suggested on typos, never wrapped).
const RESERVED: &[&str] = &["snapshot", "pty"];

/// Wall-clock seconds since the Unix epoch (shared by the CLI + PTY paths).
pub(crate) fn now_secs() -> f64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0)
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let socket = kairos_client::default_socket_path();
    let spool = kairos_client::default_spool_dir();

    match dispatch(&args, &socket, &spool) {
        Ok(code) => ExitCode::from(code),
        Err(e) => {
            eprintln!("kairos: {e}");
            ExitCode::from(1)
        }
    }
}

/// Returns the process exit code (0 = ok, 1 = cli error via `Err`, 2 = usage,
/// child's code for a PTY wrap).
fn dispatch(args: &[String], socket: &str, spool: &str) -> Result<u8, cli::CliError> {
    let first = args.first().map(String::as_str).unwrap_or("");
    match first {
        "" => {
            usage();
            Ok(2)
        }
        "help" | "-h" | "--help" => {
            usage();
            Ok(0)
        }
        "--version" | "-V" => {
            println!("kairos {}", env!("KAIROS_VERSION"));
            Ok(0)
        }
        "snapshot" => {
            eprintln!("kairos: snapshot commands are not yet implemented");
            Ok(2)
        }
        "pty" => Ok(pty::run(&args[1..], socket)),
        // `kairos --project <slug> <cmd>` / `--title <title> <cmd>` wrap <cmd>
        // (both flags, in any order, handled inside `pty::run`).
        "--project" | "--title" => Ok(pty::run(args, socket)),
        cmd if KNOWN_SUBCOMMANDS.contains(&cmd) => {
            cli::run(args, socket, spool)?;
            Ok(0)
        }
        other if other.starts_with('-') => {
            eprintln!("kairos: unknown option '{other}'");
            usage();
            Ok(2)
        }
        other if resolve_command(other) => Ok(pty::run(args, socket)),
        other => {
            eprintln!(
                "kairos: '{other}' is not a kairos subcommand and isn't an executable on PATH"
            );
            if let Some(s) = suggest(other) {
                eprintln!("  did you mean '{s}'?");
            }
            Ok(2)
        }
    }
}

fn usage() {
    eprintln!(
        "usage: kairos <activity|event|client|map|pause|owner|export> [opts]\n\
         wrap a command under a PTY:  kairos [--title <title>] [--project <slug>] <command> [args...]   (e.g. kairos claude)"
    );
}

/// Is `name` an executable — a `/`-path that is executable, or found on `PATH`?
/// (The path is discarded: `pty::run` re-resolves via the child spawn.)
fn resolve_command(name: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    let executable = |p: &Path| match std::fs::metadata(p) {
        Ok(md) => md.is_file() && md.permissions().mode() & 0o111 != 0,
        Err(_) => false,
    };
    if name.contains('/') {
        return executable(Path::new(name));
    }
    std::env::var_os("PATH")
        .is_some_and(|path| std::env::split_paths(&path).any(|dir| executable(&dir.join(name))))
}

fn suggest(other: &str) -> Option<&'static str> {
    KNOWN_SUBCOMMANDS
        .iter()
        .chain(RESERVED)
        .map(|k| (*k, levenshtein(other, k)))
        .filter(|(_, d)| *d <= 2)
        .min_by_key(|(_, d)| *d)
        .map(|(k, _)| k)
}

fn levenshtein(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut curr = vec![0; b.len() + 1];
    for (i, &ac) in a.iter().enumerate() {
        curr[0] = i + 1;
        for (j, &bc) in b.iter().enumerate() {
            let cost = if ac == bc { 0 } else { 1 };
            curr[j + 1] = (prev[j + 1] + 1).min(curr[j] + 1).min(prev[j] + cost);
        }
        std::mem::swap(&mut prev, &mut curr);
    }
    prev[b.len()]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_args_is_usage_error() {
        assert_eq!(dispatch(&[], "/x", "/y"), Ok(2));
    }

    #[test]
    fn unknown_option_is_usage_error() {
        assert_eq!(dispatch(&["--bogus".into()], "/x", "/y"), Ok(2));
    }

    #[test]
    fn title_flag_routes_to_pty_not_unknown_option() {
        // `--title` with no command reaches pty::run, which prints its own usage
        // (exit 2) — proving it did NOT hit the "unknown option" arm. A real
        // `--title X vim` would spawn a PTY, which we can't do in a unit test;
        // split_flags (pty.rs) covers the flag semantics.
        assert_eq!(dispatch(&["--title".into(), "Foo".into()], "/x", "/y"), Ok(2));
    }

    #[test]
    fn snapshot_not_implemented() {
        assert_eq!(dispatch(&["snapshot".into()], "/x", "/y"), Ok(2));
    }

    #[test]
    fn bare_command_not_on_path_is_usage_error() {
        let cmd = "kairos-definitely-not-a-real-command-zzz";
        assert_eq!(dispatch(&[cmd.into()], "/x", "/y"), Ok(2));
    }

    #[test]
    fn help_succeeds() {
        assert_eq!(dispatch(&["help".into()], "/x", "/y"), Ok(0));
    }

    #[test]
    fn suggest_finds_close_subcommand() {
        assert_eq!(suggest("activty"), Some("activity"));
        assert_eq!(suggest("evnt"), Some("event"));
        assert_eq!(suggest("completely-unrelated"), None);
    }
}
