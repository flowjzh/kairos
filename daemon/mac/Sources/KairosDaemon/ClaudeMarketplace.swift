import Foundation

/// Registers the app-bundled Claude Code plugin marketplace with Claude Code by
/// adding an `extraKnownMarketplaces` entry to `~/.claude/settings.json`. The plugin
/// itself is installed and managed with `claude plugin` commands; this only makes
/// the bundled marketplace *known*. The bundled tree — a copy of `plugins/claude-code`
/// (manifests + hooks) with the native binary — lives at
/// `Contents/Resources/plugins/claude-code`, and is a self-contained marketplace
/// (its `marketplace.json` names one plugin with `source: "."`).
enum ClaudeMarketplace {
    static var path: String { Bundle.main.bundlePath + "/Contents/Resources/plugins/claude-code" }

    /// The marketplace name, read from the bundled `marketplace.json`: the release app
    /// ships `kairos`, the dev app is stamped `kairos-dev` (Makefile), so their
    /// `extraKnownMarketplaces` entries in `~/.claude/settings.json` never collide —
    /// dev and release register, install, and cache independently.
    static let name: String = {
        let manifest = path + "/.claude-plugin/marketplace.json"
        if let data = try? Data(contentsOf: URL(fileURLWithPath: manifest)),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let declared = obj["name"] as? String { return declared }
        return "kairos"
    }()

    /// `plugin@marketplace` ref for `claude plugin install` (e.g. `kairos-claude-code@kairos-dev`).
    static var pluginRef: String { "kairos-claude-code@\(name)" }

    static var settingsPath: String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/settings.json"
    }

    /// Registered iff settings names OUR marketplace at THIS bundle's path — so the
    /// dev and release apps each reflect only their own registration.
    static var isRegistered: Bool {
        (try? load()).flatMap { marketplacePath(in: $0) } == path
    }

    static func register() -> String? { mutate { withMarketplace($0, path: path) } }
    static func unregister() -> String? { mutate(withoutMarketplace) }

    // MARK: - Pure transforms (unit-tested)

    /// The path of our marketplace entry in a settings dict, or nil.
    static func marketplacePath(in settings: [String: Any]) -> String? {
        guard let markets = settings["extraKnownMarketplaces"] as? [String: Any],
              let entry = markets[name] as? [String: Any],
              let source = entry["source"] as? [String: Any] else { return nil }
        return source["path"] as? String
    }

    /// Settings with our marketplace entry set (directory source at `path`),
    /// preserving every other key and marketplace.
    static func withMarketplace(_ settings: [String: Any], path: String) -> [String: Any] {
        var out = settings
        var markets = out["extraKnownMarketplaces"] as? [String: Any] ?? [:]
        markets[name] = ["source": ["source": "directory", "path": path]]
        out["extraKnownMarketplaces"] = markets
        return out
    }

    /// Settings with our marketplace entry removed; drops an emptied container.
    static func withoutMarketplace(_ settings: [String: Any]) -> [String: Any] {
        var out = settings
        guard var markets = out["extraKnownMarketplaces"] as? [String: Any] else { return out }
        markets.removeValue(forKey: name)
        if markets.isEmpty { out.removeValue(forKey: "extraKnownMarketplaces") }
        else { out["extraKnownMarketplaces"] = markets }
        return out
    }

    // MARK: - File IO

    /// Load settings: `[:]` if the file is absent/empty, throws if it exists but is
    /// unparseable — so `mutate` refuses to clobber a settings.json we can't read.
    private static func load() throws -> [String: Any] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: settingsPath)), !data.isEmpty
        else { return [:] }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "kairos", code: 1)
        }
        return dict
    }

    /// Read → transform → atomic write. Returns nil on success, else an error string.
    private static func mutate(_ transform: ([String: Any]) -> [String: Any]) -> String? {
        let settings: [String: Any]
        do { settings = try load() } catch {
            return "~/.claude/settings.json isn't valid JSON — fix it, then retry."
        }
        do {
            let dir = (settingsPath as NSString).deletingLastPathComponent
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: transform(settings),
                                                  options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath), options: .atomic)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
