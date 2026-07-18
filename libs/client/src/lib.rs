//! Socket client + spool fallback. Mirrors Swift `KairosClient/SocketClient`:
//! one request per Unix-domain-socket connection — write `line\n`, read the one
//! reply line (the daemon closes after responding). On connection failure,
//! ingest requests spool to `~/.kairos/spool` for the daemon to drain; reads
//! propagate the error.
//!
//! ## Spool format (log-rotate style)
//!
//! - All requests append to a single `active.jsonl` file (one JSON line per
//!   request) using atomic O_APPEND writes. Multiple concurrent hook processes
//!   safely append without locks because each write is < PIPE_BUF (4096 bytes).
//! - When `active.jsonl` exceeds the rotate threshold (default 1 MiB), it is
//!   atomically renamed to a sealed file `<uuid>.jsonl` and a new `active.jsonl`
//!   is created. The daemon drains each sealed file then deletes it.
//! - This keeps file count bounded (O(events / threshold), ~65 files for a
//!   year of heavy use) and eliminates 19× block-size waste from one-file-per-
//!   request. No compression: the daemon deletes files immediately on drain.

use std::fs::OpenOptions;
use std::io::{BufRead, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};

use kairos_codec::{decode_response, encode_request, RequestEnvelope, ResponseEnvelope};

/// Default daemon socket path: `<runtime_dir>/daemon.sock`.
pub fn default_socket_path() -> String {
    format!("{}/daemon.sock", runtime_dir())
}

/// Default spool directory: `<runtime_dir>/spool`.
pub fn default_spool_dir() -> String {
    format!("{}/spool", runtime_dir())
}

/// Default rotate threshold: 1 MiB (≈5000 request lines at ~200B each).
pub const DEFAULT_ROTATE_BYTES: u64 = 1024 * 1024;

/// The runtime dir holding the socket + spool: `$KAIROS_RUNTIME_DIR`, else
/// `$HOME/.kairos`. Overridable so a dev daemon and the release daemon can run
/// side by side (the daemon reads the same var); the CLI/plugin inherit it from
/// the shell (or Claude's hook env) and rendezvous on the right socket.
fn runtime_dir() -> String {
    runtime_dir_from(std::env::var("KAIROS_RUNTIME_DIR").ok(), &std::env::var("HOME").unwrap_or_default())
}

/// Pure resolution (env read hoisted out) so the fallback is unit-testable
/// without mutating process env — cargo runs tests in parallel threads that
/// share it.
fn runtime_dir_from(override_dir: Option<String>, home: &str) -> String {
    override_dir.unwrap_or_else(|| format!("{home}/.kairos"))
}

#[derive(Debug)]
pub struct ClientError(pub String);

impl std::fmt::Display for ClientError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ClientError {}

pub struct SocketClient {
    socket_path: PathBuf,
    spool_dir: PathBuf,
}

#[derive(Debug)]
pub enum Outcome {
    Response(ResponseEnvelope),
    Spooled,
}

impl SocketClient {
    pub fn new(socket_path: impl Into<PathBuf>, spool_dir: impl Into<PathBuf>) -> Self {
        Self { socket_path: socket_path.into(), spool_dir: spool_dir.into() }
    }

    /// Send a request. On connection failure, spool if `spoolable` (ingest
    /// commands), else error (reads).
    pub fn send(&self, request: &RequestEnvelope, spoolable: bool) -> Result<Outcome, ClientError> {
        let line = encode_request(request).map_err(|e| ClientError(e.to_string()))?;
        match self.transact(&line) {
            Ok(response_line) => {
                let response = decode_response(&response_line)
                    .map_err(|_| ClientError("malformed response".into()))?;
                Ok(Outcome::Response(response))
            }
            Err(_) if spoolable => {
                self.spool(&line).map_err(|e| ClientError(e.to_string()))?;
                Ok(Outcome::Spooled)
            }
            Err(_) => Err(ClientError("daemon unreachable".into())),
        }
    }

    fn transact(&self, line: &str) -> std::io::Result<String> {
        let mut stream = UnixStream::connect(&self.socket_path)?;
        stream.write_all(line.as_bytes())?;
        stream.write_all(b"\n")?;
        // One line per connection; read_until stops at the newline (bounded, no
        // waiting for the daemon's close to propagate as EOF).
        let mut reader = std::io::BufReader::new(stream);
        let mut buf = Vec::new();
        reader.read_until(b'\n', &mut buf)?;
        Ok(String::from_utf8_lossy(&buf).trim().to_string())
    }

    fn spool(&self, line: &str) -> std::io::Result<()> {
        spool_to(&self.spool_dir, line, DEFAULT_ROTATE_BYTES)
    }
}

/// Spool a request line to the active.jsonl file in `dir`, rotating by byte size.
/// Appends the line to `active.jsonl` with O_APPEND; if the file reaches >=
/// `rotate_bytes`, atomically renames it to `<uuid>.jsonl` (sealed) and creates
/// a new `active.jsonl`. Creates `dir` if missing. Thread-safe: concurrent
/// O_APPEND writes < PIPE_BUF are atomic, and rename is atomic.
pub fn spool_to(dir: &Path, line: &str, rotate_bytes: u64) -> std::io::Result<()> {
    let active = dir.join("active.jsonl");

    // O_APPEND gives atomic concurrent writes. create_dir_all only on the first
    // event ever: the daemon never makes the spool dir, so a fresh install needs
    // it, but the common case (dir exists) skips the mkdir syscall.
    let mut file = match OpenOptions::new().append(true).create(true).open(&active) {
        Ok(f) => f,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            std::fs::create_dir_all(dir)?;
            OpenOptions::new().append(true).create(true).open(&active)?
        }
        Err(e) => return Err(e),
    };

    writeln!(file, "{line}")?;

    // Rotate if at threshold. fstat on the open fd (no path re-resolution); the
    // write is already in the inode, so len() reflects it. Write-first keeps the
    // line safe even if rotation races — two racers may both rename, benign.
    if file.metadata()?.len() >= rotate_bytes {
        let sealed = dir.join(format!("{}.jsonl", uuid::Uuid::new_v4()));
        std::fs::rename(&active, &sealed)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn runtime_dir_falls_back_to_home_kairos() {
        assert_eq!(runtime_dir_from(None, "/Users/me"), "/Users/me/.kairos");
    }

    #[test]
    fn runtime_dir_honors_override() {
        assert_eq!(runtime_dir_from(Some("/Users/me/.kairos-dev".into()), "/Users/me"), "/Users/me/.kairos-dev");
    }

    #[test]
    fn spool_to_appends_to_active() {
        let dir = tempfile::TempDir::new().unwrap();
        let spool = dir.path();

        spool_to(spool, r#"{"method":"test1"}"#, 1000).unwrap();
        spool_to(spool, r#"{"method":"test2"}"#, 1000).unwrap();

        let active = spool.join("active.jsonl");
        let content = std::fs::read_to_string(&active).unwrap();
        let lines: Vec<&str> = content.lines().collect();
        assert_eq!(lines, vec![r#"{"method":"test1"}"#, r#"{"method":"test2"}"#]);
    }

    #[test]
    fn spool_to_rotates_at_threshold() {
        let dir = tempfile::TempDir::new().unwrap();
        let spool = dir.path();

        // Small threshold to trigger rotation quickly.
        let threshold = 50;

        // First write creates active.jsonl.
        spool_to(spool, r#"{"method":"first"}"#, threshold).unwrap();
        assert!(spool.join("active.jsonl").exists());

        // Pad to exceed threshold (50 bytes).
        for i in 0..10 {
            let line = format!(r#"{{"method":"pad{}"}}}}"#, i);
            spool_to(spool, &line, threshold).unwrap();
        }

        // active.jsonl should have been renamed to a sealed file.
        let sealed: Vec<_> = std::fs::read_dir(spool).unwrap()
            .filter_map(|e| e.ok())
            .map(|e| e.file_name())
            .filter(|n| n.to_str().map(|s| s.ends_with(".jsonl") && s != "active.jsonl").unwrap_or(false))
            .collect();
        assert!(!sealed.is_empty(), "should have at least one sealed file");

        // A new active.jsonl exists for further writes.
        assert!(spool.join("active.jsonl").exists());
    }

    #[test]
    fn spool_to_creates_dir_if_missing() {
        let dir = tempfile::TempDir::new().unwrap();
        let nested = dir.path().join("nested/spool/dir");

        assert!(!nested.exists());
        spool_to(&nested, r#"{"method":"test"}"#, 1000).unwrap();
        assert!(nested.join("active.jsonl").exists());
    }
}
