import Foundation

/// A failure a caller can show or branch on.
public enum NearError: Error, Sendable, Equatable {
    case invalidServiceType
    case invalidDisplayName
    case invalidPasscode
    case invalidDraftName
    case invalidLimit
    case draftTooLarge
    case alreadyRunning
    case notRunning
    case unknownPeer
    case notPaired
    case alreadyInProgress
    case pairingFailed
    case timedOut
    case unexpectedPeer
    case malformedFrame
    case frameTooLarge
    case integrityFailure
    case closed
    case cancelled
    case connectionFailed
    case entropyUnavailable
}

extension NearError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidServiceType:
            "The service type must be 1–15 letters, digits, or hyphens, and must not begin or end with a hyphen."
        case .invalidDisplayName:
            "The display name must be 1–63 bytes and must not contain control characters."
        case .invalidPasscode:
            "The pairing code must be 4–8 digits."
        case .invalidDraftName:
            "The draft name must be 1–120 bytes and must not be a path."
        case .invalidLimit:
            "The draft size or the pairing time is outside the range this session accepts."
        case .draftTooLarge:
            "The draft is larger than this session allows."
        case .alreadyRunning:
            "The session is already running."
        case .notRunning:
            "The session is not running."
        case .unknownPeer:
            "That device is no longer nearby."
        case .notPaired:
            "The devices have not finished pairing."
        case .alreadyInProgress:
            "A connection to that device is already underway."
        case .pairingFailed:
            "The pairing codes do not match."
        case .timedOut:
            "The other device did not finish pairing in time."
        case .unexpectedPeer:
            "The device that answered was not the device that was dialed."
        case .malformedFrame:
            "The connection sent a frame this session cannot read."
        case .frameTooLarge:
            "The connection sent a frame larger than this session allows."
        case .integrityFailure:
            "The draft failed its integrity check and was not delivered."
        case .closed:
            "The connection is closed."
        case .cancelled:
            "The session stopped."
        case .connectionFailed:
            "The connection failed."
        case .entropyUnavailable:
            "The system could not supply random bytes."
        }
    }
}
