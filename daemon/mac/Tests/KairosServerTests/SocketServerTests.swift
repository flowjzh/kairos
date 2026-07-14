import Testing
import Network
import os
import Foundation
@testable import KairosServer
import KairosCore
import KairosRPC
import KairosStore

@Suite
struct SocketServerTests {
    /// Open a socket, send one request line, read one response line.
    private func rpc(socketPath: String, requestLine: String) async throws -> String {
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
            let conn = NWConnection(to: .unix(path: socketPath), using: .tcp)
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    conn.send(content: Data((requestLine + "\n").utf8), completion: .contentProcessed { _ in
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, error in
                            if let error {
                                resumeOnce(.failure(error))
                                return
                            }
                            let line = (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            resumeOnce(.success(line))
                        }
                    })
                case .failed(let error):
                    resumeOnce(.failure(error))
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }
    }

    private func waitForSocket(_ path: String) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: path) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    @Test
    func roundTripClientsList() async throws {
        let store = try Store(path: ":memory:")
        let server = SocketServer(dispatcher: Dispatcher(), store: store)
        let socketPath = "\(NSTemporaryDirectory())kairos-test-\(UUID().uuidString).sock"
        try server.start(at: socketPath)
        defer { server.stop() }

        try await waitForSocket(socketPath)
        let requestLine = try LineCodec.encodeRequest(RequestEnvelope(method: .clientsList, params: .null))
        let responseLine = try await rpc(socketPath: socketPath, requestLine: requestLine)

        let resp = try LineCodec.decodeResponse(responseLine)
        guard case .result(let v) = resp else { Issue.record("expected result"); return }
        let list = try Wire.decodeValue(v, as: ClientsListResult.self)
        #expect(list.clients.isEmpty)
    }

    @Test
    func roundTripPostsAndReads() async throws {
        let store = try Store(path: ":memory:")
        let server = SocketServer(dispatcher: Dispatcher(), store: store)
        let socketPath = "\(NSTemporaryDirectory())kairos-test-\(UUID().uuidString).sock"
        try server.start(at: socketPath)
        defer { server.stop() }
        try await waitForSocket(socketPath)

        let addLine = try LineCodec.encodeRequest(RequestEnvelope(
            method: .clientsAdd,
            params: try Wire.encodeValue(ClientsAddParams(name: "Acme"))
        ))
        let addRespLine = try await rpc(socketPath: socketPath, requestLine: addLine)
        guard case .result(let v) = try LineCodec.decodeResponse(addRespLine) else { Issue.record(); return }
        let acme = try Wire.decodeValue(v, as: ClientsAddResult.self).id

        let listLine = try LineCodec.encodeRequest(RequestEnvelope(method: .clientsList, params: .null))
        let listRespLine = try await rpc(socketPath: socketPath, requestLine: listLine)
        guard case .result(let v) = try LineCodec.decodeResponse(listRespLine) else { Issue.record(); return }
        let list = try Wire.decodeValue(v, as: ClientsListResult.self)
        #expect(list.clients == [ClientEntry(id: acme, name: "Acme")])
    }
}
