import Foundation

/// A stable id for this device. The app stores it. NearLink does not.
public struct NearIdentity: Sendable, Hashable, Codable {
    public let id: UUID

    public init(id: UUID = UUID()) {
        self.id = id
    }
}
