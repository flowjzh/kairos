//! Socket client + spool fallback. Mirrors Swift `KairosClient/SocketClient`:
//! one request per Unix-domain-socket connection — write `line\n`, read the one
//! reply line (the daemon closes after responding). On connection failure,
//! ingest requests spool to `~/.kairos/spool/<uuid>.jsonl` for the daemon to
//! drain; reads propagate the error.

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
        std::fs::create_dir_all(&self.spool_dir)?;
        let path: &Path = &self.spool_dir.join(format!("{}.jsonl", uuid::Uuid::new_v4()));
        std::fs::write(path, format!("{line}\n"))
    }
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
}
