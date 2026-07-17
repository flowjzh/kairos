import Foundation

/// The three filesystem locations the daemon owns, resolved purely from the
/// environment so the running code has **no** notion of "dev vs release" — it
/// only reads configured dirs. Two axes, one indirection point:
///
/// - **runtime** (socket + spool): `$KAIROS_RUNTIME_DIR`, else `~/.kairos`. This
///   is where a future App-Store sandbox would point at a Group Container (the
///   socket must be reachable by non-sandboxed clients).
/// - **data** (the SQLite store): `$KAIROS_DATA_DIR`, else
///   `~/Library/Application Support/Kairos` (a sandbox's App Container).
///
/// A separate instance (the dev daemon) is just a different `$KAIROS_RUNTIME_DIR`
/// / `$KAIROS_DATA_DIR` — supplied by the build/launch config (the dev app bakes
/// them as `LSEnvironment`), never
/// branched on in code. The env vars are also how the CLI/plugin/make target a
/// given instance.
public struct KairosPaths: Sendable, Equatable {
    public let socketPath: String
    public let spoolDir: String
    public let dataDir: String
    public let dbPath: String

    public init(env: [String: String], home: String) {
        let runtime = env["KAIROS_RUNTIME_DIR"] ?? "\(home)/.kairos"
        let data = env["KAIROS_DATA_DIR"] ?? "\(home)/Library/Application Support/Kairos"
        self.socketPath = "\(runtime)/daemon.sock"
        self.spoolDir = "\(runtime)/spool"
        self.dataDir = data
        self.dbPath = "\(data)/kairos.db"
    }
}
