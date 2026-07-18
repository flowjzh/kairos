import Foundation

/// The filesystem locations the daemon owns, resolved with **no** notion of "dev
/// vs release" — it only reads configured values. Two axes, two sources:
///
/// - **runtime** (socket + spool): `$KAIROS_RUNTIME_DIR`, else `~/.kairos`.
///   Env-driven because the non-bundle Rust CLI and Claude Code hook must
///   rendezvous on the same socket — they read this var from their shell/hook
///   env. This is where a future App-Store sandbox would point at a Group
///   Container (the socket must be reachable by non-sandboxed clients).
/// - **data** (the SQLite store): the bundle's `KairosDataDir` Info.plist key,
///   else `~/Library/Application Support/Kairos` (a sandbox's App Container).
///   Bundle-baked, not env-driven: only the daemon reads it, and the daemon
///   *is* the bundle — so the value rides in the app's own Info.plist (the dev
///   app sets it at build), never threaded through the environment.
///
/// A separate instance (the dev daemon) is just a different `$KAIROS_RUNTIME_DIR`
/// plus a different `KairosDataDir` — supplied by the build (baked into the dev
/// app's bundle), never branched on in code.
public struct KairosPaths: Sendable, Equatable {
    public let socketPath: String
    public let spoolDir: String
    public let dataDir: String
    public let dbPath: String

    public init(env: [String: String], home: String, dataDir: String? = nil) {
        let runtime = env["KAIROS_RUNTIME_DIR"] ?? "\(home)/.kairos"
        let data = dataDir ?? "\(home)/Library/Application Support/Kairos"
        self.socketPath = "\(runtime)/daemon.sock"
        self.spoolDir = "\(runtime)/spool"
        self.dataDir = data
        self.dbPath = "\(data)/kairos.db"
    }
}
