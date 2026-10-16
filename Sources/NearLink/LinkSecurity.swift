import CryptoKit
import Foundation
import Security

enum NearRandom {
    static func bytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let address = buffer.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, count, address)
        }
        guard status == errSecSuccess else { throw NearError.entropyUnavailable }
        return data
    }
}

/// Each connection has its own P-256 key. The pairing code is HKDF salt, so it
/// never has to be written down on the wire. A recording of the handshake is
/// not enough to test guesses: the shared secret is not in the recording.
struct LinkSecrets {
    let proofKey: SymmetricKey
    let messageKey: SymmetricKey
    let transcript: Data

    init(shared: SharedSecret, passcode: NearPasscode, localHello: Data, remoteHello: Data) {
        let transcript = Self.transcript(localHello, remoteHello)
        let salt = Data(passcode.code.utf8)
        self.transcript = transcript
        self.proofKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("NearLink.v1.proof".utf8) + transcript,
            outputByteCount: 32
        )
        self.messageKey = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: salt,
            sharedInfo: Data("NearLink.v1.message".utf8) + transcript,
            outputByteCount: 32
        )
    }

    func proof() -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: transcript, using: proofKey))
    }

    func proofMatches(_ payload: Data) -> Bool {
        HMAC<SHA256>.isValidAuthenticationCode(payload, authenticating: transcript, using: proofKey)
    }

    private static func transcript(_ left: Data, _ right: Data) -> Data {
        if left.lexicographicallyPrecedes(right) || left == right {
            return left + right
        }
        return right + left
    }
}

struct LinkCipher {
    let key: SymmetricKey
    let localPrefix: UInt8
    let remotePrefix: UInt8
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    mutating func seal(_ plaintext: Data, kind: FrameKind) throws -> Data {
        guard sendCounter < UInt64.max else { throw NearError.integrityFailure }
        let nonce = try Self.nonce(prefix: localPrefix, counter: sendCounter)
        let box = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: Data([kind.rawValue])
        )
        sendCounter += 1
        return box.ciphertext + box.tag
    }

    mutating func open(_ boxed: Data, kind: FrameKind) throws -> Data {
        guard boxed.count >= 16 else { throw NearError.integrityFailure }
        let split = boxed.count - 16
        let ciphertext = boxed.prefix(split)
        let tag = boxed.suffix(16)
        let nonce = try Self.nonce(prefix: remotePrefix, counter: receiveCounter)
        let sealed: AES.GCM.SealedBox
        do {
            sealed = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        } catch {
            throw NearError.integrityFailure
        }
        let clear: Data
        do {
            clear = try AES.GCM.open(sealed, using: key, authenticating: Data([kind.rawValue]))
        } catch {
            throw NearError.integrityFailure
        }
        receiveCounter += 1
        return clear
    }

    private static func nonce(prefix: UInt8, counter: UInt64) throws -> AES.GCM.Nonce {
        var bytes = Data(count: 12)
        bytes[0] = prefix
        var bigEndian = counter.bigEndian
        withUnsafeBytes(of: &bigEndian) { raw in
            bytes.replaceSubrange(4..<12, with: raw)
        }
        return try AES.GCM.Nonce(data: bytes)
    }
}
