import Foundation
import Testing
@testable import NearLink

struct HandshakeTests {
    @Test func thePasscodeIsNotOnTheWire() throws {
        let (left, right, wire) = try paired(code: "481296")
        #expect(wire.range(of: Data("481296".utf8)) == nil)
        let draft = try Draft(name: "Opening", content: Data("quiet".utf8))
        let sealed = try left.seal(draft)
        #expect(sealed.range(of: Data("481296".utf8)) == nil)
        let received = try right.openDraft(sealed)
        #expect(received == draft)
    }

    @Test func aWrongCodeNeverOpens() throws {
        let left = try handshake(name: "Mac", code: "481296")
        let right = try handshake(name: "iPhone", code: "000000")
        let leftHello = left.openingFrame()
        let rightHello = right.openingFrame()
        guard case .send = left.receive(try frame(rightHello)) else {
            Issue.record("left should answer the hello")
            return
        }
        guard case .send(let rightProof) = right.receive(try frame(leftHello)) else {
            Issue.record("right should answer the hello")
            return
        }
        guard case .failed(let error) = left.receive(try frame(rightProof)) else {
            Issue.record("the proof should be refused")
            return
        }
        #expect(error == .pairingFailed)
    }

    @Test func aFlippedByteIsNotADraft() throws {
        let (left, right, _) = try paired(code: "481296")
        var sealed = try left.seal(try Draft(name: "Opening", content: Data("quiet".utf8)))
        let frameIndex = sealed.index(before: sealed.endIndex)
        sealed[frameIndex] ^= 0xff
        #expect(throws: NearError.integrityFailure) {
            try right.openDraft(sealed)
        }
    }

    private func paired(code: String) throws -> (HandshakeDriver, HandshakeDriver, Data) {
        let left = try handshake(name: "Mac", code: code)
        let right = try handshake(name: "iPhone", code: code)
        let leftHello = left.openingFrame()
        let rightHello = right.openingFrame()
        guard case .send(let leftProof) = left.receive(try frame(rightHello)),
              case .send(let rightProof) = right.receive(try frame(leftHello)),
              case .paired = left.receive(try frame(rightProof)),
              case .paired = right.receive(try frame(leftProof))
        else { throw NearError.pairingFailed }
        return (left, right, leftHello + rightHello + leftProof + rightProof)
    }

    private func handshake(name: String, code: String) throws -> HandshakeDriver {
        let session = try LinkHandshake(
            identity: NearIdentity(),
            displayName: name,
            passcode: try NearPasscode(code),
            maximumDraftBytes: 1024,
            expecting: nil
        )
        return HandshakeDriver(session)
    }

    private func frame(_ data: Data) throws -> Frame {
        var decoder = FrameDecoder(maximumPayload: 4096)
        let frames = try decoder.append(data)
        guard frames.count == 1 else { throw NearError.malformedFrame }
        return frames[0]
    }
}

/// Keeps a handshake in a class so tests can pass it around after `inout` pairing.
private final class HandshakeDriver {
    var handshake: LinkHandshake

    init(_ handshake: LinkHandshake) {
        self.handshake = handshake
    }

    func openingFrame() -> Data {
        handshake.openingFrame()
    }

    func receive(_ frame: Frame) -> HandshakeEffect {
        handshake.receive(frame)
    }

    func seal(_ draft: Draft) throws -> Data {
        try handshake.sealDraft(draft)
    }

    func openDraft(_ data: Data) throws -> Draft {
        var decoder = FrameDecoder(maximumPayload: 4096)
        let frames = try decoder.append(data)
        guard frames.count == 1 else { throw NearError.malformedFrame }
        guard case .draft(let draft) = handshake.receive(frames[0]) else {
            throw NearError.integrityFailure
        }
        return draft
    }
}
