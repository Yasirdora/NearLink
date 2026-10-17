import Foundation

/// A device discovered on the local network, then named by the pairing handshake.
public struct NearPeer: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let displayName: String

    init(id: UUID, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    public static func == (lhs: NearPeer, rhs: NearPeer) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
