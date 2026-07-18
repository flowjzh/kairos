import Foundation
import KairosRPC
import KairosStore

/// Drains the spool directory written by the Rust hook/client (log-rotate style).
///
/// ## Spool format
///
/// - Requests append to a single `active.jsonl` (one JSON line per request) using
///   atomic O_APPEND writes. Multiple concurrent hook processes safely append.
/// - When `active.jsonl` reaches the rotate threshold (default 1 MiB), the hook
///   atomically renames it to a sealed `<uuid>.jsonl` and creates a new
///   `active.jsonl`. The daemon may be down during this rotation.
///
/// ## Drain process
///
/// 1. Seal `active.jsonl` by renaming it to `<uuid>.jsonl` so it's treated like
///    any other sealed file. (If the daemon crashed mid-write, this truncates
///    the last incomplete line — the LineCodec rejects it and we drop it.)
/// 2. For each `*.jsonl` file, read line-by-line, decode each request, replay
///    through the dispatcher, then delete the file.
/// 3. Corrupt or unparsable lines are skipped; the file is deleted after all
///    parseable lines are replayed.
///
/// This keeps file count bounded (O(events / threshold)) and eliminates the
/// 19× block-size waste from one-file-per-request.
public struct Spooler {
    public let spoolDir: String

    public init(spoolDir: String) { self.spoolDir = spoolDir }

    @discardableResult
    public func drain(dispatcher: Dispatcher, store: Store) async -> Int {
        let directory = URL(fileURLWithPath: spoolDir)

        // Step 1: seal active.jsonl if it exists (rename to uuid.jsonl).
        let active = directory.appendingPathComponent("active.jsonl")
        if FileManager.default.fileExists(atPath: active.path) {
            let sealed = directory.appendingPathComponent("\(UUID().uuidString).jsonl")
            _ = try? FileManager.default.moveItem(at: active, to: sealed)
        }

        // Step 2: drain each sealed file, line by line.
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: spoolDir)
        } catch {
            return 0
        }
        var drained = 0
        // Replay order is irrelevant: each line carries its own ts and the store
        // reduces over (ts, id). names has no meaningful order, so don't sort.
        for name in names {
            guard name.hasSuffix(".jsonl") else { continue }
            let url = directory.appendingPathComponent(name)
            guard let contents = try? String(contentsOf: url, encoding: .utf8) else {
                try? FileManager.default.removeItem(at: url)
                continue
            }
            // LineCodec trims and rejects empty/blank lines — matches the live
            // socket path (SocketServer.handle), no local trim needed.
            for line in contents.split(separator: "\n") {
                guard let request = try? LineCodec.decodeRequest(String(line)) else { continue }
                _ = await dispatcher.handle(request, store: store)
                drained += 1
            }
            try? FileManager.default.removeItem(at: url)
        }
        return drained
    }
}
