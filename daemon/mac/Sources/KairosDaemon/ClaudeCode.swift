import Foundation

/// Detects a usable Claude Code CLI so the Plugins pane can gate its controls.
/// A menu-bar/background app inherits a minimal PATH, so we probe the documented
/// install locations directly (the native installer's `~/.local/bin/claude` first),
/// then fall back to the user's login shell — which sources their profile and so
/// resolves npm-global prefixes the fixed candidates miss.
enum ClaudeCode {
    /// A runnable `claude` path, or nil if none is found.
    static func detect() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "\(home)/.local/bin/claude",   // native installer (recommended location)
            "/usr/local/bin/claude",       // npm global / Homebrew (Intel)
            "/opt/homebrew/bin/claude",    // Homebrew (Apple Silicon)
        ]
        let fm = FileManager.default
        if let hit = candidates.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        return loginShellLookup()
    }

    static var isInstalled: Bool { detect() != nil }

    /// Resolve `claude` via the user's login shell (sources ~/.zprofile etc., so a
    /// PATH-based npm install is found). One short subprocess; nil on any failure.
    private static func loginShellLookup() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shell)
        proc.arguments = ["-lc", "command -v claude"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return nil }
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let path = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
