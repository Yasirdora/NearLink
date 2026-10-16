import Foundation
import Testing
@testable import NearLink

struct FrameCodecTests {
    @Test func aFrameSurvivesBeingSplit() throws {
        let frame = Frame(kind: .draft, payload: Data("a complete draft".utf8))
        let encoded = frame.encoded()
        var decoder = FrameDecoder(maximumPayload: 64)
        var produced: [Frame] = []
        for byte in encoded {
            produced.append(contentsOf: try decoder.append(Data([byte])))
        }
        #expect(produced == [frame])
    }

    @Test func twoFramesInOneChunkBothComeOut() throws {
        let first = Frame(kind: .hello, payload: Data([1, 2, 3]))
        let second = Frame(kind: .proof, payload: Data(repeating: 9, count: 32))
        var decoder = FrameDecoder(maximumPayload: 64)
        let frames = try decoder.append(first.encoded() + second.encoded())
        #expect(frames == [first, second])
    }

    @Test func aBadMagicClosesTheDecoder() {
        var decoder = FrameDecoder(maximumPayload: 64)
        let junk = Data(repeating: 0, count: 12)
        #expect(throws: NearError.malformedFrame) {
            try decoder.append(junk)
        }
    }

    @Test func aDeclaredLengthPastTheCeilingIsRefused() {
        var decoder = FrameDecoder(maximumPayload: 8)
        var header = Data()
        header.appendUInt32(Frame.magic)
        header.append(1)
        header.append(FrameKind.draft.rawValue)
        header.appendUInt16(0)
        header.appendUInt32(9)
        #expect(throws: NearError.frameTooLarge) {
            try decoder.append(header)
        }
    }

    @Test func aDraftWithTheWrongHashIsNotUnpacked() throws {
        var packed = DraftCodec.pack(name: "Note", content: Data("one".utf8))
        let contentIndex = packed.count - 1
        packed[contentIndex] ^= 0xff
        #expect(throws: NearError.integrityFailure) {
            try DraftCodec.unpack(packed, maximumContentBytes: 32)
        }
    }
}
