import Testing
import Foundation
@testable import KairosClaudeCode
import KairosRPC

@Suite
struct ClaudeCodeHookTests {
    private func input(_ event: String, cwd: String? = "/Users/me/Desktop/daemonclaw", transcript: String? = "/tmp/t.jsonl") -> HookInput {
        HookInput(sessionId: "sess-1", cwd: cwd, transcriptPath: transcript, hookEventName: event)
    }

    @Test
    func sessionStartOpensActivityWithProjectFromCwd() throws {
        let req = try #require(ClaudeCodeHook.request(from: input("SessionStart"), now: 100))
        #expect(req.method == .activitiesOpen)
        let p = try Wire.decodeValue(req.params, as: ActivitiesOpenParams.self)
        #expect(p.source == "claude-code")
        #expect(p.externalId == "sess-1")
        #expect(p.project == "daemonclaw")          // basename(cwd)
        #expect(p.metadata?["transcript_path"] == .string("/tmp/t.jsonl"))
        #expect(p.metadata?["cwd"] == .string("/Users/me/Desktop/daemonclaw"))
    }

    @Test
    func userPromptSubmitPostsAiSubmit() throws {
        let req = try #require(ClaudeCodeHook.request(from: input("UserPromptSubmit"), now: 250))
        #expect(req.method == .eventsPost)
        let p = try Wire.decodeValue(req.params, as: EventsPostParams.self)
        #expect(p.kind == "ai_submit")
        #expect(p.ts == 250)
        #expect(p.activity?.externalId == "sess-1")
    }

    @Test
    func stopPostsAiStop() throws {
        let req = try #require(ClaudeCodeHook.request(from: input("Stop"), now: 300))
        let p = try Wire.decodeValue(req.params, as: EventsPostParams.self)
        #expect(p.kind == "ai_stop")
    }

    @Test
    func sessionEndClosesActivity() throws {
        let req = try #require(ClaudeCodeHook.request(from: input("SessionEnd"), now: 400))
        #expect(req.method == .activitiesClose)
        let p = try Wire.decodeValue(req.params, as: ActivitiesCloseParams.self)
        #expect(p.externalId == "sess-1")
        #expect(p.ts == 400)
    }

    @Test
    func unknownEventIsIgnored() {
        #expect(ClaudeCodeHook.request(from: input("PreToolUse"), now: 0) == nil)
    }

    @Test
    func malformedJSONIsIgnored() {
        #expect(ClaudeCodeHook.request(fromJSON: Data("not json".utf8), now: 0) == nil)
    }

    @Test
    func decodesRealHookJSON() throws {
        let json = Data("""
        {"session_id":"abc","cwd":"/w/proj","transcript_path":"/t.jsonl","hook_event_name":"Stop"}
        """.utf8)
        let req = try #require(ClaudeCodeHook.request(fromJSON: json, now: 5))
        #expect(req.method == .eventsPost)
    }

    @Test
    func sessionStartWithoutCwdHasNoProject() throws {
        let req = try #require(ClaudeCodeHook.request(from: input("SessionStart", cwd: nil, transcript: nil), now: 1))
        let p = try Wire.decodeValue(req.params, as: ActivitiesOpenParams.self)
        #expect(p.project == nil)
        #expect(p.metadata == nil)
    }
}
