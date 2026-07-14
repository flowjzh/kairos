import Foundation

public enum Method: String, Codable, Sendable {
    case activitiesStart = "activities.start"
    case activitiesStop = "activities.stop"
    case activitiesEnsure = "activities.ensure"
    case eventsPost = "events.post"
    case focusReport = "focus.report"
    case focusSet = "focus.set"
    case controlPause = "control.pause"
    case notifyUser = "notify.user"
    case clientsList = "clients.list"
    case clientsAdd = "clients.add"
    case clientsRename = "clients.rename"
    case mappingList = "mapping.list"
    case mappingSet = "mapping.set"
    case segmentsGet = "segments.get"
    case focusedGet = "focused.get"
}
