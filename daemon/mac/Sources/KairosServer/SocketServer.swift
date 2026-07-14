import Foundation
import Network
import KairosRPC
import KairosStore

/// Serves the line-JSON RPC over a Unix domain socket. One request per
/// connection: read a line, dispatch, write a response line, close. The
/// daemon owns one of these; the socket is `chmod 0600` (same-user only).
public final class SocketServer: @unchecked Sendable {
    private let dispatcher: Dispatcher
    private let store: Store
    private let queue = DispatchQueue(label: "kairos.socket")
    private var listener: NWListener?
    private var socketPath: String?

    public init(dispatcher: Dispatcher, store: Store) {
        self.dispatcher = dispatcher
        self.store = store
    }

    public func start(at path: String) throws {
        try? FileManager.default.removeItem(atPath: path)
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: path)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
        self.socketPath = path
        chmod(path, 0o600)
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        if let socketPath { try? FileManager.default.removeItem(atPath: socketPath) }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        readLine(from: connection) { [weak self] line in
            guard let self, let line else { connection.cancel(); return }
            Task {
                let response: ResponseEnvelope
                if let request = try? LineCodec.decodeRequest(line) {
                    response = await self.dispatcher.handle(request, store: self.store)
                } else {
                    response = .error(RPCError(code: "bad_request", message: "malformed request"))
                }
                let encoded = (try? LineCodec.encodeResponse(response))
                    ?? "{\"error\":{\"code\":\"internal\",\"message\":\"encode failed\"}}"
                self.write(connection, data: Data((encoded + "\n").utf8)) {
                    connection.cancel()
                }
            }
        }
    }

    private func readLine(from connection: NWConnection, accumulated: Data = Data(), completion: @escaping @Sendable (String?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            guard error == nil else { completion(nil); return }
            var acc = accumulated
            if let data { acc.append(data) }
            if let newline = acc.firstIndex(of: 0x0A) {
                completion(String(data: acc.prefix(newline), encoding: .utf8))
            } else if isComplete {
                completion(acc.isEmpty ? nil : String(data: acc, encoding: .utf8))
            } else {
                self.readLine(from: connection, accumulated: acc, completion: completion)
            }
        }
    }

    private func write(_ connection: NWConnection, data: Data, completion: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in completion() })
    }
}
