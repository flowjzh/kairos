import Testing
import Foundation
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

/// Reader half of the spool-format contract. The writer is
/// `libs/client/src/lib.rs::spool_to` (pinned by its unit tests); the format is a
/// cross-language wire contract, so — like the codec (`libs/codec/tests/codec.rs`
/// mirrors `KairosRPCTests`) — both sides are tested. These cover the reader's
/// half: append-to-`active.jsonl` + sealed `<uuid>.jsonl`, multi-line files,
/// corrupt-line skipping, file deletion, and leaving stray non-spool files alone.
@Suite
struct SpoolerTests {
    private let d = Dispatcher()

    private func startLine(_ externalId: String) throws -> String {
        let params = ActivitiesStartParams(source: "claude-code", externalId: externalId, project: nil, title: nil, metadata: nil)
        let env = RequestEnvelope(method: .activitiesStart, params: try Wire.encodeValue(params))
        return try LineCodec.encodeRequest(env)
    }

    private func makeSpoolDir() -> String {
        let dir = NSTemporaryDirectory() + "kairos-spool-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ dir: String, _ file: String, _ lines: [String]) {
        let url = URL(fileURLWithPath: dir).appendingPathComponent(file)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    private func spoolFiles(_ dir: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    }

    @Test
    func drainReplaysEachLineAndDeletesFiles() async throws {
        let dir = makeSpoolDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        // active.jsonl: two valid lines interleaved with a corrupt one.
        write(dir, "active.jsonl", [try startLine("s1"), "not-json{", try startLine("s2")])
        // A sealed file the Rust writer produced on rotation.
        write(dir, "\(UUID().uuidString).jsonl", [try startLine("s3")])

        let store = try Store(path: ":memory:")
        let drained = await Spooler(spoolDir: dir).drain(dispatcher: d, store: store)
        let visible = try await store.visibleActivities().count

        #expect(drained == 3)              // only the 3 valid lines
        #expect(spoolFiles(dir).isEmpty)   // every *.jsonl deleted
        #expect(visible == 3)              // all replayed into the store
    }

    @Test
    func drainLeavesStrayNonSpoolFiles() async throws {
        let dir = makeSpoolDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        write(dir, "active.jsonl", [try startLine("s1")])
        write(dir, ".DS_Store", ["ignored"])   // a stray non-spool file must survive

        let store = try Store(path: ":memory:")
        let drained = await Spooler(spoolDir: dir).drain(dispatcher: d, store: store)

        #expect(drained == 1)
        #expect(spoolFiles(dir) == [".DS_Store"])
    }

    @Test
    func drainEmptyDirIsNoOp() async throws {
        let dir = makeSpoolDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }

        let store = try Store(path: ":memory:")
        let drained = await Spooler(spoolDir: dir).drain(dispatcher: d, store: store)
        #expect(drained == 0)
    }
}
