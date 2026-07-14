import Testing
@testable import KairosCore

@Suite
struct EventKindTests {
    @Test
    func rawValuesMatchSpec() {
        #expect(EventKind.activityOpen.rawValue == "activity_open")
        #expect(EventKind.activityClose.rawValue == "activity_close")
        #expect(EventKind.activityOverride.rawValue == "activity_override")
        #expect(EventKind.aiStop.rawValue == "ai_stop")
        #expect(EventKind.aiSubmit.rawValue == "ai_submit")
        #expect(EventKind.afkOn.rawValue == "afk_on")
        #expect(EventKind.afkOff.rawValue == "afk_off")
        #expect(EventKind.pauseOn.rawValue == "pause_on")
        #expect(EventKind.pauseOff.rawValue == "pause_off")
        #expect(EventKind.forceOwner.rawValue == "force_owner")
    }
}
