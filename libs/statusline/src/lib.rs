//! Pure renderer for the `activities.status` result: turns the structured
//! `{activity, state, total, today}` (or `{error}`) dict into one colored
//! statusline string. Shared by every agent plugin's statusline command — the
//! plugin only parses its agent's stdin to get the session id, then calls this.
//!
//! Layout: `Activity: <name> [Focused] 🕐<total> [<today>]` — space-separated
//! (no pipes). Identity is omitted when null (line starts at the state). The
//! state is a colored bracketed tag; total is a clock-prefixed duration; today
//! follows in brackets. Colors: identity = green; state = its color key (green
//! / light-green / gray); error = red. 256-color codes for light-green/gray so
//! they render distinctly (the basic bright codes wash out on some terminals).

use kairos_codec::ActivityStatusResult;

const RESET: &str = "\x1b[0m";
/// Stopwatch glyph, text-presentation (U+FE0E) so it renders as a monochrome
/// font glyph rather than a colorful emoji.
const CLOCK: &str = "\u{23F1}\u{FE0E}";

/// Map a daemon color key to its ANSI foreground sequence.
fn ansi(color: &str) -> &'static str {
    match color {
        "green" => "\x1b[32m",
        "light-green" => "\x1b[38;5;65m",
        "gray" => "\x1b[38;5;244m",
        "red" => "\x1b[31m",
        _ => "",
    }
}

/// Wrap `body` in a color and reset — the one colored-span shape used everywhere.
fn colored(color: &str, body: &str) -> String {
    format!("{}{}{}", ansi(color), body, RESET)
}

/// Render an `activities.status` result as a single statusline string.
pub fn render(result: &ActivityStatusResult) -> String {
    // Error shape: a single red "{label}: {text}" — the only thing to show.
    if let Some(err) = &result.error {
        let body = err.text.as_deref().unwrap_or("");
        return colored("red", &format!("{}: {}", err.label, body));
    }

    let mut parts: Vec<String> = Vec::new();

    // Activity name (title ?? project, resolved daemon-side) with its label;
    // skipped entirely when null/empty so the line can start at the state.
    if let Some(act) = &result.activity {
        if let Some(text) = act.text.as_deref().filter(|s| !s.is_empty()) {
            parts.push(colored("green", &format!("{}: {}", act.label, text)));
        }
    }

    // State: plain brackets framing the colored word, e.g. `[Focused]` /
    // `[Gracing]` / `[Idle]` — the brackets match the plain time text, the word
    // carries the state color.
    if let Some(state) = &result.state {
        if let Some(text) = &state.text {
            let word = match state.color.as_deref() {
                Some(c) => colored(c, text),
                None => text.clone(),
            };
            parts.push(format!("[{word}]"));
        }
    }

    // Total: a clock glyph, a space, then the duration. Today: in brackets.
    if let Some(total) = &result.total {
        if let Some(text) = &total.text {
            parts.push(format!("{CLOCK} {text}"));
        }
    }
    if let Some(today) = &result.today {
        if let Some(text) = &today.text {
            parts.push(format!("[{text}]"));
        }
    }

    parts.join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;
    use kairos_codec::ActivityStatusField;

    fn field(label: &str, text: Option<&str>, color: Option<&str>) -> ActivityStatusField {
        ActivityStatusField {
            label: label.into(),
            text: text.map(str::to_string),
            color: color.map(str::to_string),
        }
    }

    fn normal(name: Option<&str>, state: &str, color: &str, total: &str, today: &str) -> ActivityStatusResult {
        ActivityStatusResult {
            activity: Some(field("Activity", name, None)),
            state: Some(field("Status", Some(state), Some(color))),
            total: Some(field("Total", Some(total), None)),
            today: Some(field("Today", Some(today), None)),
            error: None,
        }
    }

    #[test]
    fn renders_full_line_with_name() {
        let r = normal(Some("My Task"), "Focused", "green", "1h23m", "12m");
        let out = render(&r);
        assert_eq!(
            out,
            format!("\x1b[32mActivity: My Task\x1b[0m [\x1b[32mFocused\x1b[0m] {CLOCK} 1h23m [12m]")
        );
    }

    #[test]
    fn name_skipped_when_null_starts_at_state() {
        let r = normal(None, "Idle", "gray", "0m", "0m");
        let out = render(&r);
        // No leading space — the line begins at the state tag.
        assert_eq!(out, format!("[\x1b[38;5;244mIdle\x1b[0m] {CLOCK} 0m [0m]"));
        assert!(!out.starts_with(' '), "no dangling leading space");
    }

    #[test]
    fn error_renders_red_label_colon_text() {
        let r = ActivityStatusResult {
            activity: None,
            state: None,
            total: None,
            today: None,
            error: Some(field("错误", Some("未能找到对应的活动"), Some("red"))),
        };
        assert_eq!(render(&r), "\x1b[31m错误: 未能找到对应的活动\x1b[0m");
    }

    #[test]
    fn gracing_state_uses_light_green() {
        let r = normal(Some("T"), "Gracing", "light-green", "1m", "1m");
        let out = render(&r);
        // Plain brackets frame a light-green word.
        assert!(out.contains("[\x1b[38;5;65mGracing\x1b[0m]"), "gracing tag");
    }

    #[test]
    fn state_brackets_plain_word_colored() {
        // Brackets are plain (no ANSI); only the word carries the state color.
        for (state, color, word_ansi) in [
            ("Focused", "green", "\x1b[32m"),
            ("Gracing", "light-green", "\x1b[38;5;65m"),
            ("Idle", "gray", "\x1b[38;5;244m"),
        ] {
            let r = normal(Some("T"), state, color, "1m", "1m");
            let out = render(&r);
            assert!(out.contains(&format!("[{word_ansi}{state}\x1b[0m]")), "{state}: plain brackets, colored word");
        }
    }

    #[test]
    fn no_pipes_and_bracketed_today() {
        let r = normal(Some("T"), "Focused", "green", "1h23m", "12m");
        let out = render(&r);
        assert!(!out.contains('|'), "no pipe separators");
        assert!(out.contains(&format!("{CLOCK} 1h23m [12m]")), "clock + space + total, bracketed today");
    }

    #[test]
    fn colored_segments_each_reset() {
        // Every colored span closes with reset so color can't bleed into the
        // following segment. The trailing time segments are uncolored, so the
        // whole line need not end in reset — only colored spans do.
        let r = normal(Some("T"), "Focused", "green", "1m", "1m");
        let out = render(&r);
        assert!(out.matches(RESET).count() >= 2, "activity + state both reset");
        assert!(!out.contains(&format!("\x1b[32m{CLOCK}")), "no color bleeds into time segments");

        // Error line ends in reset (the whole span is red).
        let err = ActivityStatusResult {
            activity: None, state: None, total: None, today: None,
            error: Some(field("错误", Some("x"), Some("red"))),
        };
        assert!(render(&err).ends_with(RESET));
    }
}
