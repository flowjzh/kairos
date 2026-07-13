import Foundation
import Network
import os
import KairosRPC

/// Error raised when the daemon socket can't be reached (and the request isn't
/// spoolable). Kept local to `KairosClient` so the transport doesn't depend on
/// any CLI type — the plugin binary and the `kairos` CLI both link this.
public struct ClientError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Sends one request line over the socket and reads one response line. On
/// connection failure, ingest requests are spooled to disk for the daemon to
/// drain later; reads propagate the error.
public struct SocketClient {
    public enum Outcome {
        case response(ResponseEnvelope)
        case spooled
    }

    public let socketPath: String
    public let spoolDir: String

    public init(socketPath: String, spoolDir: String) {
        self.socketPath = socketPath
        self.spoolDir = spoolDir
    }

    public func send(_ request: RequestEnvelope, spoolable: Bool) async throws -> Outcome {
        let line = try LineCodec.encodeRequest(request)
        do {
            let responseLine = try await transact(line)
            return .response(try LineCodec.decodeResponse(responseLine))
        } catch {
            guard spoolable else { throw error }
            try spool(line)
            return .spooled
        }
    }

    private func transact(_ requestLine: String) async throws -> String {
        let resumed = OSAllocatedUnfairLock(initialState: false)
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let resumeOnce: @Sendable (Result<String, Error>) -> Void = { result in
                let first = resumed.withLock { (state: inout Bool) -> Bool in
                    if state { return false }
                    state = true
                    return true
                }
                guard first else { return }
                cont.resume(with: result)
            }
            let connection = NWConnection(to: .unix(path: socketPath), using: .tcp)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.send(content: Data((requestLine + "\n").utf8), completion: .contentProcessed { _ in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, _, error in
                            if let error {
                                resumeOnce(.failure(error))
                                return
                            }
                            let line = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            connection.cancel()
                            resumeOnce(.success(line))
                        }
                    })
                case .failed(let error):
                    resumeOnce(.failure(error))
                case .waiting:
                    // Daemon isn't there (missing socket) — don't hang retrying.
                    resumeOnce(.failure(ClientError("daemon unreachable")))
                    connection.cancel()
                default:
                    break
                }
            }
            connection.start(queue: .global())
        }
    }

    private func spool(_ requestLine: String) throws {
        try FileManager.default.createDirectory(atPath: spoolDir, withIntermediateDirectories: true)
        let path = "\(spoolDir)/\(UUID().uuidString).jsonl"
        try (requestLine + "\n").data(using: .utf8)!.write(to: URL(fileURLWithPath: path))
    }
}
