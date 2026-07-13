import Foundation
import KairosRPC

/// The JSON object Claude Code passes to a hook command on stdin (the subset
/// Kairos needs). Keys per the Claude Code hooks contract.
public struct HookInput: Codable, Sendable {
    public let sessionId: String
    public let cwd: String?
    public let transcriptPath: String?
    public let hookEventName: String

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd
        case transcriptPath = "transcript_path"
        case hookEventName = "hook_event_name"
    }

    public init(sessionId: String, cwd: String?, transcriptPath: String?, hookEventName: String) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.hookEventName = hookEventName
    }
}

/// Maps a Claude Code hook event to a Kairos RPC. This is the *only* Claude
/// Code-specific knowledge in the system — the daemon and `kairos` CLI stay
/// agent-agnostic (ADR 12/20); a different agent ships its own binary with its
/// own mapping. Pure and `now`-injected so it is unit-testable.
public enum ClaudeCodeHook {
    public static let source = "claude-code"

    /// Decode stdin bytes then map; nil if the JSON is malformed or the event
    /// isn't one we track (the caller exits 0 regardless — never disrupt Claude).
    public static func request(fromJSON data: Data, now: Double) -> RequestEnvelope? {
        guard let input = try? JSONDecoder().decode(HookInput.self, from: data) else { return nil }
        return request(from: input, now: now)
    }

    public static func request(from input: HookInput, now: Double) -> RequestEnvelope? {
        let activity = ActivityRef(source: source, externalId: input.sessionId)
        switch input.hookEventName {
        case "SessionStart":
            let project = input.cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
            var metadata: [String: JSONValue] = [:]
            if let path = input.transcriptPath { metadata["transcript_path"] = .string(path) }
            if let cwd = input.cwd { metadata["cwd"] = .string(cwd) }
            return try? RequestEnvelope(method: .activitiesOpen, params: Wire.encodeValue(
                ActivitiesOpenParams(source: source, externalId: input.sessionId, project: project,
                                     title: nil, metadata: metadata.isEmpty ? nil : metadata)))
        case "UserPromptSubmit":
            return event(activity, kind: "ai_submit", now: now)
        case "Stop":
            return event(activity, kind: "ai_stop", now: now)
        case "SessionEnd":
            return try? RequestEnvelope(method: .activitiesClose, params: Wire.encodeValue(
                ActivitiesCloseParams(source: source, externalId: input.sessionId, ts: now)))
        default:
            return nil
        }
    }

    private static func event(_ activity: ActivityRef, kind: String, now: Double) -> RequestEnvelope? {
        try? RequestEnvelope(method: .eventsPost, params: Wire.encodeValue(
            EventsPostParams(activity: activity, kind: kind, ts: now, payload: nil)))
    }
}
