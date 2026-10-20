import Foundation

/// What the session reports. Subscribe before calling `start` if the first sighting matters.
public enum NearEvent: Sendable, Equatable {
    /// A device with this service type appeared.
    case discovered(NearPeer)
    /// A device left, or its advertisement stopped.
    case lost(NearPeer.ID)
    /// The pairing code matched. Drafts may be sent.
    case paired(NearPeer)
    /// A paired device disconnected.
    case disconnected(NearPeer.ID)
    /// A complete draft. The seal and the content hash both checked.
    case received(Draft, from: NearPeer.ID)
    /// Pairing did not finish. No draft from this attempt was delivered.
    case rejected(NearPeer.ID)
    /// A failure that is not tied to one peer, or that happened before the peer was known.
    case failed(NearError)
}
