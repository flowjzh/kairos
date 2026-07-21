import Foundation

/// Human-facing display names for the daemon's built-in sources. Plugins own
/// their own labels (reported via `source_display_name`); the daemon owns these.
/// Locale-aware so the seeded `display_name` matches the host language. The
/// `language` is the daemon's resolved code (`AppSettings.effectiveLanguage`:
/// `"en"` or `"zh-Hans"`).
public enum SourceLabels {
    public static func display(slug: String, language: String) -> String {
        let zh = language.hasPrefix("zh")
        switch slug {
        case "manual": return zh ? "手动" : "Manual"
        case "pty": return zh ? "终端" : "Terminal"
        default: return slug
        }
    }
}
