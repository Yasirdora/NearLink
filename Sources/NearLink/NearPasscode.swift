import Foundation
import Security

/// A short code shown on one device and entered on the other.
///
/// The value is a pairing secret, not a password. Keep it off the wire.
public struct NearPasscode: Sendable, Equatable {
    fileprivate let digits: String

    public init(_ digits: String) throws {
        guard Self.isValid(digits) else { throw NearError.invalidPasscode }
        self.digits = digits
    }

    /// Six digits unless `length` says otherwise. Digits are unbiased.
    public static func generate(length: Int = 6) throws -> NearPasscode {
        guard (4...8).contains(length) else { throw NearError.invalidPasscode }
        var digits = ""
        digits.reserveCapacity(length)
        while digits.count < length {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else { throw NearError.entropyUnavailable }
            // 250 is the largest multiple of 10 that fits in a byte.
            guard byte < 250 else { continue }
            digits.append(String(Int(byte % 10)))
        }
        return try NearPasscode(digits)
    }

    /// The code to show or to compare with what the person typed.
    public var code: String { digits }

    static func isValid(_ digits: String) -> Bool {
        (4...8).contains(digits.count) && digits.allSatisfy(\.isASCIIDigit)
    }
}

extension NearPasscode: CustomDebugStringConvertible {
    public var debugDescription: String { "NearPasscode(\(digits.count) digits)" }
}

private extension Character {
    var isASCIIDigit: Bool {
        guard let ascii = asciiValue else { return false }
        return ascii >= 48 && ascii <= 57
    }
}
