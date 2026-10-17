import CryptoKit
import Foundation

struct Hello: Equatable {
    var id: UUID
    var nonce: Data
    var publicKey: Data
    var displayName: String

    func encoded() -> Data {
        var data = Data()
        data.append(Self.bytes(of: id))
        data.append(nonce)
        data.append(publicKey)
        let name = Data(displayName.utf8)
        data.appendUInt16(UInt16(name.count))
        data.append(name)
        return data
    }

    static func decode(_ payload: Data) throws -> Hello {
        var reader = ByteReader(payload)
        let id = Self.uuid(try reader.take(16))
        let nonce = try reader.take(16)
        let publicKey = try reader.take(64)
        let nameCount = Int(try reader.uint16())
        let nameBytes = try reader.take(nameCount)
        guard reader.isEmpty() else { throw NearError.malformedFrame }
        guard let name = String(bytes: nameBytes, encoding: .utf8), DisplayName.isValid(name) else {
            throw NearError.malformedFrame
        }
        return Hello(id: id, nonce: nonce, publicKey: publicKey, displayName: name)
    }

    static func bytes(of id: UUID) -> Data {
        withUnsafeBytes(of: id.uuid) { Data($0) }
    }

    static func uuid(_ bytes: Data) -> UUID {
        var value = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &value) { destination in
            destination.copyBytes(from: bytes.prefix(16))
        }
        return UUID(uuid: value)
    }
}

enum HandshakeEffect: Equatable {
    case send(Data)
    case paired(NearPeer)
    case draft(Draft)
    case goodbye
    case failed(NearError)
}

struct LinkHandshake {
    private let localHello: Hello
    private let localHelloBytes: Data
    private let passcode: NearPasscode
    private let maximumDraftBytes: Int
    private let expecting: UUID?
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var secrets: LinkSecrets?
    private var cipher: LinkCipher?
    private(set) var remote: NearPeer?
    private var phase: Phase = .expectHello

    private enum Phase {
        case expectHello
        case expectProof
        case open
        case failed
    }

    init(
        identity: NearIdentity,
        displayName: String,
        passcode: NearPasscode,
        maximumDraftBytes: Int,
        expecting: UUID?
    ) throws {
        let key = P256.KeyAgreement.PrivateKey()
        let hello = Hello(
            id: identity.id,
            nonce: try NearRandom.bytes(16),
            publicKey: key.publicKey.rawRepresentation,
            displayName: displayName
        )
        self.localHello = hello
        self.localHelloBytes = hello.encoded()
        self.passcode = passcode
        self.maximumDraftBytes = maximumDraftBytes
        self.expecting = expecting
        self.privateKey = key
    }

    mutating func openingFrame() -> Data {
        Frame(kind: .hello, payload: localHelloBytes).encoded()
    }

    mutating func receive(_ frame: Frame) -> HandshakeEffect {
        guard phase != .failed else { return .failed(.malformedFrame) }
        switch (phase, frame.kind) {
        case (.expectHello, .hello):
            return takeHello(frame.payload)
        case (.expectProof, .proof):
            return takeProof(frame.payload)
        case (.open, .draft):
            return takeDraft(frame.payload)
        case (.open, .goodbye):
            return takeGoodbye(frame.payload)
        default:
            phase = .failed
            return .failed(.malformedFrame)
        }
    }

    mutating func sealDraft(_ draft: Draft) throws -> Data {
        guard phase == .open else { throw NearError.notPaired }
        guard draft.content.count <= maximumDraftBytes else { throw NearError.draftTooLarge }
        let packed = DraftCodec.pack(name: draft.name, content: draft.content)
        let sealed = try seal(packed, kind: .draft)
        return Frame(kind: .draft, payload: sealed).encoded()
    }

    mutating func sealGoodbye() throws -> Data {
        guard phase == .open else { throw NearError.notPaired }
        let sealed = try seal(Data(), kind: .goodbye)
        return Frame(kind: .goodbye, payload: sealed).encoded()
    }

    private mutating func takeHello(_ payload: Data) -> HandshakeEffect {
        let remoteHello: Hello
        do {
            remoteHello = try Hello.decode(payload)
            let remoteKey = try P256.KeyAgreement.PublicKey(rawRepresentation: remoteHello.publicKey)
            guard let privateKey else { throw NearError.malformedFrame }
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: remoteKey)
            secrets = LinkSecrets(
                shared: shared,
                passcode: passcode,
                localHello: localHelloBytes,
                remoteHello: payload
            )
            self.privateKey = nil
        } catch let error as NearError {
            phase = .failed
            return .failed(error)
        } catch {
            phase = .failed
            return .failed(.malformedFrame)
        }

        if remoteHello.id == localHello.id {
            phase = .failed
            return .failed(.unexpectedPeer)
        }
        if let expecting, remoteHello.id != expecting {
            remote = NearPeer(id: remoteHello.id, displayName: remoteHello.displayName)
            phase = .failed
            return .failed(.unexpectedPeer)
        }

        remote = NearPeer(id: remoteHello.id, displayName: remoteHello.displayName)
        guard let secrets else {
            phase = .failed
            return .failed(.malformedFrame)
        }
        phase = .expectProof
        return .send(Frame(kind: .proof, payload: secrets.proof()).encoded())
    }

    private mutating func takeProof(_ payload: Data) -> HandshakeEffect {
        guard let secrets, let remote else {
            phase = .failed
            return .failed(.malformedFrame)
        }
        guard secrets.proofMatches(payload) else {
            phase = .failed
            return .failed(.pairingFailed)
        }
        let localBytes = Hello.bytes(of: localHello.id)
        let remoteBytes = Hello.bytes(of: remote.id)
        guard localBytes != remoteBytes else {
            phase = .failed
            return .failed(.unexpectedPeer)
        }
        let localIsLow = localBytes.lexicographicallyPrecedes(remoteBytes)
        cipher = LinkCipher(
            key: secrets.messageKey,
            localPrefix: localIsLow ? 0 : 1,
            remotePrefix: localIsLow ? 1 : 0
        )
        self.secrets = nil
        phase = .open
        return .paired(remote)
    }

    private mutating func takeDraft(_ payload: Data) -> HandshakeEffect {
        do {
            let clear = try open(payload, kind: .draft)
            let draft = try DraftCodec.unpack(clear, maximumContentBytes: maximumDraftBytes)
            return .draft(draft)
        } catch let error as NearError {
            phase = .failed
            return .failed(error == .draftTooLarge ? error : .integrityFailure)
        } catch {
            phase = .failed
            return .failed(.integrityFailure)
        }
    }

    private mutating func takeGoodbye(_ payload: Data) -> HandshakeEffect {
        do {
            _ = try open(payload, kind: .goodbye)
            return .goodbye
        } catch {
            phase = .failed
            return .failed(.integrityFailure)
        }
    }

    private mutating func seal(_ plaintext: Data, kind: FrameKind) throws -> Data {
        guard var cipher else { throw NearError.notPaired }
        do {
            let sealed = try cipher.seal(plaintext, kind: kind)
            self.cipher = cipher
            return sealed
        } catch let error as NearError {
            throw error
        } catch {
            throw NearError.integrityFailure
        }
    }

    private mutating func open(_ payload: Data, kind: FrameKind) throws -> Data {
        guard var cipher else { throw NearError.notPaired }
        let clear = try cipher.open(payload, kind: kind)
        self.cipher = cipher
        return clear
    }
}
