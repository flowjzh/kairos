import Foundation
import KairosRPC
import KairosStore

/// Drains the spool directory: each `*.jsonl` file holds one request line
/// written by the CLI while the daemon was down. Replay them through the
/// dispatcher, then remove the files.
public struct Spooler {
    public let spoolDir: String

    public init(spoolDir: String) { self.spoolDir = spoolDir }

    @discardableResult
    public func drain(dispatcher: Dispatcher, store: Store) async -> Int {
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: spoolDir)
        } catch {
            return 0
        }
        let directory = URL(fileURLWithPath: spoolDir)
        var drained = 0
        for name in names.sorted() {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let line = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let request = try? LineCodec.decodeRequest(line) else {
                try? FileManager.default.removeItem(at: url)   // corrupt file — drop it
                continue
            }
            _ = await dispatcher.handle(request, store: store)
            try? FileManager.default.removeItem(at: url)
            drained += 1
        }
        return drained
    }
}
