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
}
