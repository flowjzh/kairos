import Testing
@testable import KairosCLI
import KairosRPC

@Suite
struct CLITests {
    private let now: Double = 1_000_000

    private func flags(_ tokens: [String]) -> Flags { parseFlags(tokens) }

    @Test
    func eventBuildsEventsPost() throws {
        let f = flags(["--source", "claude-code", "--id", "s1", "--kind", "ai_submit"])
        let request = try buildRequest(command: "event", subcommand: nil, flags: f, now: now)
        #expect(request.method == .eventsPost)
        let p = try Wire.decodeValue(request.params, as: EventsPostParams.self)
        #expect(p.activity?.source == "claude-code")
        #expect(p.activity?.externalId == "s1")
        #expect(p.kind == "ai_submit")
        #expect(p.ts == now)
    }

    @Test
    func activityOpenBuildsRequest() throws {
        let f = flags(["--source", "claude-code", "--id", "s1", "--project", "daemonclaw", "--title", "Build"])
        let request = try buildRequest(command: "activity", subcommand: "open", flags: f, now: now)
        #expect(request.method == .activitiesOpen)
        let p = try Wire.decodeValue(request.params, as: ActivitiesOpenParams.self)
        #expect(p.project == "daemonclaw")
        #expect(p.title == "Build")
    }

    @Test
    func clientAddFromPositional() throws {
        let f = flags(["Acme Corp"])
        let request = try buildRequest(command: "client", subcommand: "add", flags: f, now: now)
        #expect(request.method == .clientsAdd)
        #expect(try Wire.decodeValue(request.params, as: ClientsAddParams.self).name == "Acme Corp")
    }

    @Test
    func mapSetWithBillableFlag() throws {
        let f = flags(["--project", "p1", "--client", "3", "--no-billable"])
        let request = try buildRequest(command: "map", subcommand: "set", flags: f, now: now)
        let p = try Wire.decodeValue(request.params, as: MappingSetParams.self)
        #expect(p.project == "p1")
        #expect(p.clientId == 3)
        #expect(p.billable == false)
    }

    @Test
    func exportBuildsSegmentsGet() throws {
        let f = flags(["--from", "0", "--to", "1000", "--client", "5"])
        let request = try buildRequest(command: "export", subcommand: nil, flags: f, now: now)
        #expect(request.method == .segmentsGet)
        let p = try Wire.decodeValue(request.params, as: SegmentsGetParams.self)
        #expect(p.from == 0)
        #expect(p.to == 1000)
        #expect(p.client == 5)
    }

    @Test
    func exportToDefaultsToNow() throws {
        let request = try buildRequest(command: "export", subcommand: nil, flags: flags(["--from", "0"]), now: 5000)
        let p = try Wire.decodeValue(request.params, as: SegmentsGetParams.self)
        #expect(p.from == 0)
        #expect(p.to == 5000)
    }

    @Test
    func exportAcceptsISOFrom() throws {
        let midnight = parseTime("2026-07-13T00:00:00", now: 0)
        let request = try buildRequest(command: "export", subcommand: nil, flags: flags(["--from", "2026-07-13T00:00:00"]), now: 0)
        let p = try Wire.decodeValue(request.params, as: SegmentsGetParams.self)
        #expect(p.from == midnight)
    }

    @Test
    func parseTimeAcceptsEpochNowAndISO() {
        #expect(parseTime("9999999999", now: 0) == 9999999999)
        #expect(parseTime("now", now: 1234) == 1234)
        #expect(parseTime("2026-07-13", now: 0) != nil)
        #expect(parseTime("2026-07-13T12:00:00", now: 0) != nil)
        #expect(parseTime("not-a-date", now: 0) == nil)
    }

    @Test
    func pauseDefaultsToOn() throws {
        let request = try buildRequest(command: "pause", subcommand: "on", flags: flags([]), now: now)
        #expect(try Wire.decodeValue(request.params, as: ControlPauseParams.self).paused == true)
    }

    @Test
    func mapUnsetEmitsTombstone() throws {
        let f = flags(["--project", "p1"])
        let request = try buildRequest(command: "map", subcommand: "unset", flags: f, now: now)
        let p = try Wire.decodeValue(request.params, as: MappingSetParams.self)
        #expect(p.clientId == nil)
    }
}
