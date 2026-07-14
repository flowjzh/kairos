// swift-tools-version: 6.0
import PackageDescription

// The Swift daemon. The CLI, PTY wrapper, and Claude Code hook binary are Rust
// (root Cargo workspace: libs/codec, libs/client, cli, plugins/claude-code).
// `KairosRPC` here is the Swift hand-mirror of the canonical Rust `libs/codec`.
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

        // Line-JSON wire types + codec — the Swift hand-mirror of the canonical
        // Rust `libs/codec` (kept in sync by discipline + tests, no codegen).
        .target(name: "KairosRPC", path: "Sources/KairosRPC"),

        // Socket server + request dispatcher (testable; linked into the daemon).
        .target(name: "KairosServer", dependencies: ["KairosCore", "KairosStore", "KairosRPC"], path: "Sources/KairosServer"),

        // Resident menu-bar daemon.
        .executableTarget(name: "KairosDaemon", dependencies: ["KairosCore", "KairosStore", "KairosRPC", "KairosServer"], path: "Sources/KairosDaemon"),

        .testTarget(name: "KairosCoreTests", dependencies: ["KairosCore"], path: "Tests/KairosCoreTests"),
        .testTarget(name: "KairosRPCTests", dependencies: ["KairosRPC"], path: "Tests/KairosRPCTests"),
        .testTarget(name: "KairosStoreTests", dependencies: ["KairosStore"], path: "Tests/KairosStoreTests"),
        .testTarget(name: "KairosServerTests", dependencies: ["KairosServer"], path: "Tests/KairosServerTests"),
    ]
)
