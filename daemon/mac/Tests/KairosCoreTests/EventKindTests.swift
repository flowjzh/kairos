import Testing
@testable import KairosCore

@Suite
struct EventKindTests {
    @Test
    func slugsMatchWire() {
        #expect(EventKind.aiStop.slug == "ai_stop")
        #expect(EventKind.aiSubmit.slug == "ai_submit")
        #expect(EventKind.focus.slug == "focus")
        #expect(EventKind.blur.slug == "blur")
        #expect(EventKind.afkOn.slug == "afk_on")
        #expect(EventKind.afkOff.slug == "afk_off")
        #expect(EventKind.pauseOn.slug == "pause_on")
        #expect(EventKind.pauseOff.slug == "pause_off")
        #expect(EventKind.activityOverride.slug == "activity_override")
    }

    @Test
    func slugRoundTrips() {
        for kind in EventKind.allCases {
            #expect(EventKind(slug: kind.slug) == kind)
        }
        #expect(EventKind(slug: "activity_open") == nil)   // removed in M4p3
    }

    @Test
    func storageIsStableInt() {
        // The Int rawValue is the DB storage code and must not be reordered.
        #expect(EventKind.aiStop.rawValue == 1)
        #expect(EventKind.focus.rawValue == 3)
        #expect(EventKind.activityOverride.rawValue == 9)
    }

    @Test
    func activityStateSlugs() {
        #expect(ActivityState.visible.rawValue == 0)
        #expect(ActivityState.archived.slug == "archived")
        #expect(ActivityState(slug: "archived") == .archived)
    }
}
