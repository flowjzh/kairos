import Foundation

/// User-tunable settings, stored via `UserDefaults` — the macOS-standard
/// preferences store (`~/Library/Preferences/<bundle-id>.plist`). Per bundle id,
/// so the dev and release instances keep independent settings with no dev/release
/// branch in code: both read `UserDefaults.standard`. The Configure window's
/// `@AppStorage` fields bind these same keys, so a change in the UI is visible to
/// the daemon on the next read (and persists across launches).
///
/// `register()` must run at launch before any read — `UserDefaults` returns `0`
/// for an unset `Double`, and grace `0` is a valid "off" value, so we can't infer
/// "unset" from the read; the registered default is the only signal.
public enum AppSettings {
    public static let graceKey = "kairos.grace.seconds"
    public static let idleThresholdKey = "kairos.idle.threshold"

    public static let defaultGrace: Double = 120
    public static let defaultIdleThreshold: Double = 60

    public static func register() {
        UserDefaults.standard.register(defaults: [
            graceKey: defaultGrace,
            idleThresholdKey: defaultIdleThreshold,
        ])
    }

    // Get-only: writes go through the `@AppStorage` bindings in Configure, which
    // hit UserDefaults directly — there is no second write path to expose here.
    public static var grace: Double { UserDefaults.standard.double(forKey: graceKey) }
    public static var idleThreshold: Double { UserDefaults.standard.double(forKey: idleThresholdKey) }

    // UI language is resolved natively: Configure writes `AppleLanguages`, and
    // Bundle.main picks the right .lproj on the next launch (it caches at launch,
    // so a change only takes effect after relaunch). `AppleLanguages` is the single
    // source — persisted across restarts — so the Picker needs no second key. Any
    // `zh*` → zh-Hans; anything else → en (the dev-region catch-all).
    public static var effectiveLanguage: String {
        if let code = UserDefaults.standard.array(forKey: "AppleLanguages")?.first as? String {
            return resolve(code)
        }
        return resolve(Bundle.main.preferredLocalizations.first ?? "en")
    }
    // The language Bundle.main resolved at launch — captured once (lazily, on first
    // access at launch). The General pane compares the Picker against this to show
    // the "next launch" hint for a pending change.
    public static let launchLanguage = effectiveLanguage

    private static func resolve(_ code: String) -> String { code.hasPrefix("zh") ? "zh-Hans" : "en" }
}
