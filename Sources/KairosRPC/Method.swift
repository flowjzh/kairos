import Foundation

public enum Method: String, Codable, Sendable {
    case activitiesOpen = "activities.open"
    case activitiesClose = "activities.close"
    case eventsPost = "events.post"
    case controlPause = "control.pause"
    case controlOwner = "control.owner"
    case clientsList = "clients.list"
    case clientsAdd = "clients.add"
    case clientsRename = "clients.rename"
    case mappingList = "mapping.list"
    case mappingSet = "mapping.set"
    case segmentsGet = "segments.get"
    case ownerGet = "owner.get"
}
