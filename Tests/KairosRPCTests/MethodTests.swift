import Testing
@testable import KairosRPC

@Suite
struct MethodTests {
    @Test
    func rawValuesMatchSpec() {
        #expect(Method.activitiesOpen.rawValue == "activities.open")
        #expect(Method.activitiesClose.rawValue == "activities.close")
        #expect(Method.eventsPost.rawValue == "events.post")
        #expect(Method.controlPause.rawValue == "control.pause")
        #expect(Method.controlOwner.rawValue == "control.owner")
        #expect(Method.clientsList.rawValue == "clients.list")
        #expect(Method.clientsAdd.rawValue == "clients.add")
        #expect(Method.clientsRename.rawValue == "clients.rename")
        #expect(Method.mappingList.rawValue == "mapping.list")
        #expect(Method.mappingSet.rawValue == "mapping.set")
        #expect(Method.segmentsGet.rawValue == "segments.get")
        #expect(Method.ownerGet.rawValue == "owner.get")
    }
}
