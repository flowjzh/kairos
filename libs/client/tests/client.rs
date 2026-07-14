//! Port of the socket-client behavior: spool format + a round-trip through an
//! in-process Unix socket listener.

use std::io::{Read, Write};
use std::os::unix::net::UnixListener;

use kairos_client::{Outcome, SocketClient};
use kairos_codec::{Method, RequestEnvelope, ResponseEnvelope::Error as ErrResp, Value};

fn tmp_name(suffix: &str) -> String {
    format!("kairos-test-{}-{suffix}", uuid::Uuid::new_v4())
}

#[test]
fn spool_writes_request_line_with_newline() {
    let dir = std::env::temp_dir().join(tmp_name("spool"));
    // A nonexistent socket → connect fails → spool (spoolable).
    let client = SocketClient::new("/nonexistent/kairos-daemon.sock", &dir);
    let req = RequestEnvelope::new(Method::ClientsList, Value::Null);
    let outcome = client.send(&req, true).unwrap();
    assert!(matches!(outcome, Outcome::Spooled));

    let mut entries = std::fs::read_dir(&dir).unwrap();
    let entry = entries.next().unwrap().unwrap();
    assert!(entry.file_name().to_string_lossy().ends_with(".jsonl"));
    assert!(entries.next().is_none(), "exactly one spool file");

    let body = std::fs::read_to_string(entry.path()).unwrap();
    assert!(body.ends_with('\n'));
    let line = body.trim();
    assert!(line.contains(r#""method":"clients.list""#));
}

#[test]
fn send_round_trips_through_socket() {
    let sock = std::env::temp_dir().join(tmp_name("sock"));
    let _ = std::fs::remove_file(&sock);
    let listener = UnixListener::bind(&sock).unwrap();
    let sock_clone = sock.clone();
    let handle = std::thread::spawn(move || {
        let (mut s, _) = listener.accept().unwrap();
        let mut buf = [0u8; 4096];
        let _ = s.read(&mut buf);
        s.write_all(br#"{"error":{"code":"ok","message":"echo"}}"#).unwrap();
        s.write_all(b"\n").unwrap();
        // drop s → closes the connection (client sees EOF)
    });

    let client = SocketClient::new(&sock_clone, std::env::temp_dir());
    let req = RequestEnvelope::new(Method::ClientsList, Value::Null);
    let outcome = client.send(&req, false).unwrap();
    match outcome {
        Outcome::Response(ErrResp(e)) => assert_eq!(e.code, "ok"),
        _ => panic!("expected an error response, got {outcome:?}"),
    }
    handle.join().unwrap();
    let _ = std::fs::remove_file(&sock);
}

#[test]
fn read_propagates_error_when_unreachable() {
    let dir = std::env::temp_dir().join(tmp_name("read"));
    let client = SocketClient::new("/nonexistent/kairos-daemon.sock", &dir);
    let req = RequestEnvelope::new(Method::ClientsList, Value::Null);
    // spoolable=false → connection failure propagates as an error (reads).
    assert!(client.send(&req, false).is_err());
}
