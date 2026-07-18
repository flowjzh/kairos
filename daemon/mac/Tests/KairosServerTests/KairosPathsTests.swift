import Testing
@testable import KairosServer

@Suite struct KairosPathsTests {
    let home = "/Users/me"

    @Test func defaultsWhenNoEnv() {
        let p = KairosPaths(env: [:], home: home)
        #expect(p.socketPath == "/Users/me/.kairos/daemon.sock")
        #expect(p.spoolDir == "/Users/me/.kairos/spool")
        #expect(p.dataDir == "/Users/me/Library/Application Support/Kairos")
        #expect(p.dbPath == "/Users/me/Library/Application Support/Kairos/kairos.db")
    }

    @Test func runtimeEnvOverridesRuntimeOnly() {
        let p = KairosPaths(env: ["KAIROS_RUNTIME_DIR": "/tmp/rt"], home: home)
        #expect(p.socketPath == "/tmp/rt/daemon.sock")
        #expect(p.spoolDir == "/tmp/rt/spool")
        // data axis is independent — still the default.
        #expect(p.dbPath == "/Users/me/Library/Application Support/Kairos/kairos.db")
    }

    @Test func dataDirParamOverridesDataOnly() {
        let p = KairosPaths(env: [:], home: home, dataDir: "/tmp/data")
        #expect(p.dataDir == "/tmp/data")
        #expect(p.dbPath == "/tmp/data/kairos.db")
        #expect(p.socketPath == "/Users/me/.kairos/daemon.sock")
    }

    @Test func runtimeEnvAndDataDirGiveAnIsolatedInstance() {
        let p = KairosPaths(
            env: ["KAIROS_RUNTIME_DIR": "/Users/me/.kairos-dev"],
            home: home,
            dataDir: "/Users/me/Library/Application Support/Kairos-dev"
        )
        #expect(p.socketPath == "/Users/me/.kairos-dev/daemon.sock")
        #expect(p.dbPath == "/Users/me/Library/Application Support/Kairos-dev/kairos.db")
    }
}
