// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kairos",
    platforms: [.macOS(.v14)],
    targets: [
        // System libsqlite3 wrapper (stay-native; no third-party SQLite dependency).
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),

        // Pure attribution + domain types. No IO, no AppKit.
        .target(name: "KairosCore", path: "Sources/KairosCore"),

        // SQLite layer: schema, migrations, CRUD, resolution. Links CSQLite.
        .target(name: "KairosStore", dependencies: ["KairosCore", "CSQLite"], path: "Sources/KairosStore"),

        // Line-JSON wire types + codec. No deps (CLI links this alone — ADR 17).
        .target(name: "KairosRPC", path: "Sources/KairosRPC"),

        // Socket client + spool fallback. Shared by the CLI and agent plugins.
        .target(name: "KairosClient", dependencies: ["KairosRPC"], path: "Sources/KairosClient"),

        // Claude Code hook → RPC mapping (the only agent-specific knowledge).
        .target(name: "KairosClaudeCode", dependencies: ["KairosRPC"], path: "Sources/KairosClaudeCode"),

        // Socket server + request dispatcher (testable; linked into the daemon).
        .target(name: "KairosServer", dependencies: ["KairosCore", "KairosStore", "KairosRPC"], path: "Sources/KairosServer"),

        // CLI logic (arg parse + socket client + spool); testable.
        .target(name: "KairosCLI", dependencies: ["KairosClient", "KairosRPC"], path: "Sources/KairosCLI"),

        // Resident menu-bar daemon.
        .executableTarget(name: "KairosDaemon", dependencies: ["KairosCore", "KairosStore", "KairosRPC", "KairosServer"], path: "Sources/KairosDaemon"),

        // Thin socket client CLI.
        .executableTarget(name: "kairos", dependencies: ["KairosCLI"], path: "Sources/kairos"),

        // Claude Code plugin hook binary.
        .executableTarget(name: "kairos-claude-code", dependencies: ["KairosClaudeCode", "KairosClient"], path: "Sources/kairos-claude-code"),

        .testTarget(name: "KairosCoreTests", dependencies: ["KairosCore"], path: "Tests/KairosCoreTests"),
        .testTarget(name: "KairosRPCTests", dependencies: ["KairosRPC"], path: "Tests/KairosRPCTests"),
        .testTarget(name: "KairosStoreTests", dependencies: ["KairosStore"], path: "Tests/KairosStoreTests"),
        .testTarget(name: "KairosServerTests", dependencies: ["KairosServer", "KairosClaudeCode"], path: "Tests/KairosServerTests"),
        .testTarget(name: "KairosCLITests", dependencies: ["KairosCLI"], path: "Tests/KairosCLITests"),
        .testTarget(name: "KairosClaudeCodeTests", dependencies: ["KairosClaudeCode"], path: "Tests/KairosClaudeCodeTests"),
    ]
)
