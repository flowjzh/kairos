//! Pure scanner for terminal focus events (DECSET 1004): `ESC [ I` on focus-in
//! and `ESC [ O` on focus-out. Observe-only — it never mutates the byte stream,
//! it just reports the transitions it sees, so the wrapper can forward every
//! byte to the child unchanged (Claude enables 1004 itself and expects them).
//!
//! Fed incrementally, so a sequence split across `read()` boundaries (`ESC [`
//! then `I`) is still recognised. Other CSI input — arrow keys (`ESC [ A`),
//! bracketed paste (`ESC [ 2 0 0 ~`) — must not false-positive.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Focus {
    In,
    Out,
}

#[derive(Default)]
enum State {
    #[default]
    Ground,
    Esc,
    Bracket,
}

#[derive(Default)]
pub struct FocusScanner {
    state: State,
}

impl FocusScanner {
    pub fn feed(&mut self, bytes: &[u8]) -> Vec<Focus> {
        let mut out = Vec::new();
        for &b in bytes {
            self.state = match (&self.state, b) {
                (State::Ground, 0x1B) => State::Esc,
                (State::Esc, b'[') => State::Bracket,
                (State::Bracket, b'I') => {
                    out.push(Focus::In);
                    State::Ground
                }
                (State::Bracket, b'O') => {
                    out.push(Focus::Out);
                    State::Ground
                }
                // A stray ESC re-arms from any state (resync).
                (_, 0x1B) => State::Esc,
                // Any other byte ends the pending sequence.
                _ => State::Ground,
            };
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scan(chunks: &[&[u8]]) -> Vec<Focus> {
        let mut s = FocusScanner::default();
        let mut out = Vec::new();
        for c in chunks {
            out.extend(s.feed(c));
        }
        out
    }

    #[test]
    fn bare_focus_in() {
        assert_eq!(scan(&[b"\x1b[I"]), vec![Focus::In]);
    }

    #[test]
    fn bare_focus_out() {
        assert_eq!(scan(&[b"\x1b[O"]), vec![Focus::Out]);
    }

    #[test]
    fn split_after_bracket() {
        assert_eq!(scan(&[b"\x1b[", b"I"]), vec![Focus::In]);
    }

    #[test]
    fn split_after_esc() {
        assert_eq!(scan(&[b"\x1b", b"[", b"O"]), vec![Focus::Out]);
    }

    #[test]
    fn plain_text_is_not_focus() {
        assert_eq!(scan(&[b"hello I O world"]), vec![]);
    }

    #[test]
    fn arrow_keys_are_not_focus() {
        assert_eq!(scan(&[b"\x1b[A\x1b[B\x1b[C\x1b[D"]), vec![]);
    }

    #[test]
    fn bracketed_paste_is_not_focus() {
        assert_eq!(scan(&[b"\x1b[200~pasted\x1b[201~"]), vec![]);
    }

    #[test]
    fn interleaved_with_input() {
        assert_eq!(scan(&[b"a\x1b[Ib\x1b[Oc"]), vec![Focus::In, Focus::Out]);
    }

    #[test]
    fn double_esc_resyncs() {
        // ESC ESC [ I — the first ESC is abandoned, the sequence still parses.
        assert_eq!(scan(&[b"\x1b\x1b[I"]), vec![Focus::In]);
    }
}
