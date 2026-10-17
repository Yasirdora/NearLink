import Foundation

/// What one side needs before it advertises or browses.
public struct NearConfiguration: Sendable {
    public let serviceType: String
    public let identity: NearIdentity
    public let displayName: String
    public let passcode: NearPasscode
    public let maximumDraftBytes: Int
    public let handshakeTimeout: Duration

    public init(
        serviceType: String,
        identity: NearIdentity,
        displayName: String,
        passcode: NearPasscode,
        maximumDraftBytes: Int = 8_388_608,
        handshakeTimeout: Duration = .seconds(10)
    ) throws {
        self.serviceType = try ServiceType.normalize(serviceType)
        guard DisplayName.isValid(displayName) else { throw NearError.invalidDisplayName }
        guard (1...16_777_216).contains(maximumDraftBytes) else { throw NearError.invalidLimit }
        guard handshakeTimeout >= .milliseconds(100), handshakeTimeout <= .seconds(60) else {
            throw NearError.invalidLimit
        }
        self.identity = identity
        self.displayName = displayName
        self.passcode = passcode
        self.maximumDraftBytes = maximumDraftBytes
        self.handshakeTimeout = handshakeTimeout
    }

    var bonjourType: String { "_\(serviceType)._tcp" }

    var framePayloadCeiling: Int { maximumDraftBytes + 512 }
}

extension NearConfiguration: CustomDebugStringConvertible {
    public var debugDescription: String {
        "NearConfiguration(service: \(serviceType), name: \(displayName))"
    }
}

enum ServiceType {
    static func normalize(_ raw: String) throws -> String {
        let value = raw.lowercased()
        guard (1...15).contains(value.count) else { throw NearError.invalidServiceType }
        guard value.allSatisfy(Self.isLabelCharacter) else { throw NearError.invalidServiceType }
        guard let first = value.first, let last = value.last, first != "-", last != "-" else {
            throw NearError.invalidServiceType
        }
        return value
    }

    private static func isLabelCharacter(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue else { return false }
        let isLetter = ascii >= 97 && ascii <= 122
        let isDigit = ascii >= 48 && ascii <= 57
        return isLetter || isDigit || ascii == 45
    }
}

enum DisplayName {
    static func isValid(_ name: String) -> Bool {
        let count = Data(name.utf8).count
        guard (1...63).contains(count) else { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}
