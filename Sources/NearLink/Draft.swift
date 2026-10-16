import CryptoKit
import Foundation

/// One named body of bytes. A send carries one draft, complete or not at all.
public struct Draft: Sendable, Equatable {
    public let name: String
    public let content: Data

    public init(name: String, content: Data) throws {
        guard DraftName.isValid(name) else { throw NearError.invalidDraftName }
        self.name = name
        self.content = content
    }
}

enum DraftName {
    static func isValid(_ name: String) -> Bool {
        let count = Data(name.utf8).count
        guard (1...120).contains(count) else { return false }
        if name == "." || name == ".." { return false }
        if name.contains("/") || name.contains("\\") { return false }
        return name.unicodeScalars.allSatisfy { !CharacterSet.controlCharacters.contains($0) }
    }
}

enum DraftCodec {
    static func pack(name: String, content: Data) -> Data {
        var data = Data()
        let nameBytes = Data(name.utf8)
        data.appendUInt16(UInt16(nameBytes.count))
        data.append(nameBytes)
        data.append(Data(SHA256.hash(data: content)))
        data.append(content)
        return data
    }

    static func unpack(_ data: Data, maximumContentBytes: Int) throws -> Draft {
        var reader = ByteReader(data)
        let nameCount = Int(try reader.uint16())
        let nameBytes = try reader.take(nameCount)
        guard let name = String(bytes: nameBytes, encoding: .utf8), DraftName.isValid(name) else {
            throw NearError.malformedFrame
        }
        let digest = try reader.take(32)
        let content = reader.remaining()
        guard content.count <= maximumContentBytes else { throw NearError.draftTooLarge }
        let actual = Data(SHA256.hash(data: content))
        guard constantTimeEqual(digest, actual) else { throw NearError.integrityFailure }
        return try Draft(name: name, content: content)
    }
}

func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (left, right) in zip(lhs, rhs) {
        difference |= left ^ right
    }
    return difference == 0
}
