import Foundation

public enum EventKind: String, Codable, Sendable {
    case activityOpen = "activity_open"
    case activityClose = "activity_close"
    case activityOverride = "activity_override"
    case aiStop = "ai_stop"
    case aiSubmit = "ai_submit"
    case afkOn = "afk_on"
    case afkOff = "afk_off"
    case pauseOn = "pause_on"
    case pauseOff = "pause_off"
    case forceOwner = "force_owner"
}
