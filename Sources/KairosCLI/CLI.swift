import Foundation
import KairosClient
import KairosRPC

public struct CLIError: Error, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Parsed CLI flags. `--key value` / `--key=value`; `--no-billable` is a
/// boolean; `--meta k=v` (repeatable) populates `metadata`; bare tokens are
/// positional.
public struct Flags {
    public var values: [String: String] = [:]
    public var metadata: [String: String] = [:]
    public var positional: [String] = []

    public func value(_ key: String) -> String? { values[key] }
    public func double(_ key: String) -> Double? { values[key].flatMap(Double.init) }

    public func require(_ key: String) throws -> String {
        guard let v = values[key] else { throw CLIError("missing required --\(key)") }
        return v
    }

    public func metadataValue() throws -> [String: JSONValue]? {
        metadata.isEmpty ? nil : metadata.mapValues { .string($0) }
    }
}

public func parseFlags(_ args: [String]) -> Flags {
    var flags = Flags()
    var i = 0
    while i < args.count {
        let token = args[i]
        if token == "--no-billable" {
            flags.values["billable"] = "false"
        } else if token.hasPrefix("--meta=") {
            applyMeta(token.dropFirst("--meta=".count), into: &flags)
        } else if token == "--meta", i + 1 < args.count {
            i += 1
            applyMeta(Substring(args[i]), into: &flags)
        } else if token.hasPrefix("--") {
            let key = Substring(token.dropFirst(2))
            if let eq = key.firstIndex(of: "=") {
                flags.values[String(key[..<eq])] = String(key[key.index(after: eq)...])
            } else if i + 1 < args.count {
                i += 1
                flags.values[String(key)] = args[i]
            }
        } else {
            flags.positional.append(token)
        }
        i += 1
    }
    return flags
}

private func applyMeta(_ raw: Substring, into flags: inout Flags) {
    guard let eq = raw.firstIndex(of: "=") else { return }
    flags.metadata[String(raw[..<eq])] = String(raw[raw.index(after: eq)...])
}

/// Parse a time argument: epoch seconds, an ISO date/time (local when no
/// offset is given), or the literal "now". Returns nil if unparseable.
public func parseTime(_ raw: String?, now: Double) -> Double? {
    guard let raw else { return nil }
    if raw == "now" { return now }
    if let epoch = Double(raw) { return epoch }
    return parseISO(raw)
}

private let isoFormatters: [DateFormatter] = {
    ["yyyy-MM-dd'T'HH:mm:ssZZZZZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"].map { format in
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = format
        return formatter
    }
}()

private func parseISO(_ s: String) -> Double? {
    for formatter in isoFormatters {
        if let date = formatter.date(from: s) { return date.timeIntervalSince1970 }
    }
    return nil
}

private func requireTime(_ flags: Flags, _ key: String, now: Double) throws -> Double {
    guard let time = parseTime(flags.value(key), now: now) else {
        throw CLIError("missing or invalid --\(key) (epoch seconds, ISO date/time, or 'now')")
    }
    return time
}

/// Build the wire request for a parsed command. Pure; tested in isolation.
public func buildRequest(command: String, subcommand: String?, flags: Flags, now: Double) throws -> RequestEnvelope {
    switch command {
    case "activity":
        switch subcommand {
        case "open":
            return RequestEnvelope(method: .activitiesOpen, params: try Wire.encodeValue(ActivitiesOpenParams(
                source: try flags.require("source"), externalId: flags.value("id"),
                project: flags.value("project"), title: flags.value("title"), metadata: try flags.metadataValue())))
        case "close":
            return RequestEnvelope(method: .activitiesClose, params: try Wire.encodeValue(ActivitiesCloseParams(
                source: try flags.require("source"), externalId: flags.value("id"), ts: flags.double("ts") ?? now)))
        default:
            throw CLIError("usage: kairos activity open|close ...")
        }
    case "event":
        return RequestEnvelope(method: .eventsPost, params: try Wire.encodeValue(EventsPostParams(
            activity: ActivityRef(source: try flags.require("source"), externalId: try flags.require("id")),
            kind: try flags.require("kind"), ts: flags.double("ts") ?? now, payload: nil)))
    case "pause":
        return RequestEnvelope(method: .controlPause, params: try Wire.encodeValue(ControlPauseParams(
            paused: subcommand != "off", ts: flags.double("ts") ?? now)))
    case "owner":
        return RequestEnvelope(method: .controlOwner, params: try Wire.encodeValue(ControlOwnerParams(
            source: try flags.require("source"), externalId: flags.value("id"), ts: flags.double("ts") ?? now)))
    case "client":
        switch subcommand {
        case "add":
            guard let name = flags.positional.first else { throw CLIError("usage: kairos client add <name>") }
            return RequestEnvelope(method: .clientsAdd, params: try Wire.encodeValue(ClientsAddParams(name: name)))
        case "rename":
            guard flags.positional.count >= 2,
                  let id = Int64(flags.positional[0]) else { throw CLIError("usage: kairos client rename <id> <name>") }
            return RequestEnvelope(method: .clientsRename, params: try Wire.encodeValue(ClientsRenameParams(id: id, name: flags.positional[1])))
        case "list":
            return RequestEnvelope(method: .clientsList, params: .null)
        default:
            throw CLIError("usage: kairos client add|rename|list ...")
        }
    case "map":
        switch subcommand {
        case "set":
            return RequestEnvelope(method: .mappingSet, params: try Wire.encodeValue(MappingSetParams(
                project: try flags.require("project"),
                clientId: flags.value("client").flatMap { Int64($0) },
                billable: flags.value("billable").map { $0 != "false" } ?? true)))
        case "unset":
            return RequestEnvelope(method: .mappingSet, params: try Wire.encodeValue(MappingSetParams(
                project: try flags.require("project"), clientId: nil, billable: true)))
        case "list":
            return RequestEnvelope(method: .mappingList, params: .null)
        default:
            throw CLIError("usage: kairos map set|unset|list ...")
        }
    case "export":
        return RequestEnvelope(method: .segmentsGet, params: try Wire.encodeValue(SegmentsGetParams(
            from: try requireTime(flags, "from", now: now),
            to: parseTime(flags.value("to"), now: now) ?? now,
            project: flags.value("project"), client: flags.value("client").flatMap { Int64($0) })))
    case "snapshot":
        throw CLIError("snapshot commands are M3 (not yet implemented)")
    default:
        throw CLIError("unknown command: \(command)")
    }
}

/// Entry point. Builds the request, sends it over the socket, and prints the
/// result. Ingest commands spool to `spoolDir` if the daemon is unreachable;
/// reads error out instead.
public enum CLI {
    public static func run(
        args: [String],
        socketPath: String,
        spoolDir: String,
        now: @Sendable () -> Double = { Date().timeIntervalSince1970 }
    ) async throws {
        guard let command = args.first else {
            throw CLIError("usage: kairos <activity|event|client|map|pause|owner|export> ...")
        }
        var subcommand: String?
        var flagArgs = Array(args.dropFirst())
        if ["activity", "client", "map", "pause"].contains(command),
           let first = flagArgs.first, !first.hasPrefix("-") {
            subcommand = first
            flagArgs = Array(flagArgs.dropFirst())
        }
        let flags = parseFlags(flagArgs)
        let request = try buildRequest(command: command, subcommand: subcommand, flags: flags, now: now())

        let isRead = command == "export"
            || (command == "client" && subcommand == "list")
            || (command == "map" && subcommand == "list")
        let client = SocketClient(socketPath: socketPath, spoolDir: spoolDir)

        switch try await client.send(request, spoolable: !isRead) {
        case .spooled:
            print("spooled (daemon unreachable)")
        case .response(let response):
            switch response {
            case .error(let error):
                throw CLIError("\(error.code): \(error.message)")
            case .result(let value):
                if isRead {
                    print(String(decoding: try Wire.data(value), as: UTF8.self))
                } else if command == "activity", subcommand == "open",
                          let id = try? Wire.decodeValue(value, as: ActivitiesOpenResult.self).activityId {
                    print(id)
                } else {
                    print("ok")
                }
            }
        }
    }
}
