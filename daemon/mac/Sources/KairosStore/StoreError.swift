import Foundation

public enum StoreError: Error, Sendable {
    case sqlite(message: String)
    case notFound(String)
}
