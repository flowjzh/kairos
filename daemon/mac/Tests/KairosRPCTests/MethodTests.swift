import Testing
@testable import KairosRPC

@Suite
struct MethodTests {
    @Test
    func rawValuesMatchSpec() {
        #expect(Method.activitiesStart.rawValue == "activities.start")
        #expect(Method.activitiesStop.rawValue == "activities.stop")
        #expect(Method.activitiesEnsure.rawValue == "activities.ensure")
        #expect(Method.eventsPost.rawValue == "events.post")
        #expect(Method.focusReport.rawValue == "focus.report")
        #expect(Method.focusSet.rawValue == "focus.set")
        #expect(Method.controlPause.rawValue == "control.pause")
        #expect(Method.notifyUser.rawValue == "notify.user")
        #expect(Method.clientsList.rawValue == "clients.list")
        #expect(Method.clientsAdd.rawValue == "clients.add")
        #expect(Method.clientsRename.rawValue == "clients.rename")
        #expect(Method.mappingList.rawValue == "mapping.list")
        #expect(Method.mappingSet.rawValue == "mapping.set")
        #expect(Method.segmentsGet.rawValue == "segments.get")
        #expect(Method.focusedGet.rawValue == "focused.get")
        #expect(Method.activitiesStatus.rawValue == "activities.status")
    }
}
