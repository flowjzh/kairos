//! Best-effort focus reporter: one line-JSON `focus.report` per transition over
//! the Kairos Unix socket, one request per connection (matching the daemon's
//! read-one-line / write-one-line model). Any failure is dropped — focus is
//! live telemetry, and a stale report replayed later would be worse than a gap.

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::focus::Focus;

pub struct Reporter {
    socket: PathBuf,
    session: String,
}

impl Reporter {
    pub fn new(session: String) -> Self {
        let home = std::env::var("HOME").unwrap_or_default();
        Reporter {
            socket: PathBuf::from(format!("{home}/.kairos/daemon.sock")),
            session,
        }
    }

    pub fn report(&self, focus: Focus) {
        let _ = self.try_report(focus);
    }

    fn try_report(&self, focus: Focus) -> std::io::Result<()> {
        let ts = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs_f64())
            .unwrap_or(0.0);
        let line = serde_json::json!({
            "method": "focus.report",
            "params": {
                "kairos_session_id": self.session,
                "focused": matches!(focus, Focus::In),
                "ts": ts,
            }
        })
        .to_string();

        let mut stream = UnixStream::connect(&self.socket)?;
        stream.write_all(line.as_bytes())?;
        stream.write_all(b"\n")?;
        let mut scratch = [0u8; 256]; // drain the one-line reply, ignore it
        let _ = stream.read(&mut scratch);
        Ok(())
    }
}
