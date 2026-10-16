import Foundation

enum FrameKind: UInt8 {
    case hello = 1
    case proof = 2
    case draft = 3
    case goodbye = 4
}

struct Frame: Equatable {
    var kind: FrameKind
    var payload: Data

    static let magic: UInt32 = 0x4E524C31
    static let headerCount = 12

    func encoded() -> Data {
        var data = Data()
        data.appendUInt32(Self.magic)
        data.append(1)
        data.append(kind.rawValue)
        data.appendUInt16(0)
        data.appendUInt32(UInt32(payload.count))
        data.append(payload)
        return data
    }
}

struct FrameDecoder {
    private var buffer = Data()
    let maximumPayload: Int

    init(maximumPayload: Int) {
        self.maximumPayload = maximumPayload
    }

    mutating func append(_ chunk: Data) throws -> [Frame] {
        guard !chunk.isEmpty else { return [] }
        var frames: [Frame] = []
        var offset = 0
        while offset < chunk.count {
            let limit = Frame.headerCount + maximumPayload
            if buffer.count >= limit {
                buffer.removeAll(keepingCapacity: false)
                throw NearError.frameTooLarge
            }
            let end = min(chunk.count, offset + (limit - buffer.count))
            buffer.append(chunk[offset..<end])
            offset = end
            while true {
                guard let frame = try nextFrame() else { break }
                frames.append(frame)
            }
        }
        return frames
    }

    private mutating func nextFrame() throws -> Frame? {
        guard buffer.count >= Frame.headerCount else { return nil }
        let magic = buffer.uint32(at: 0)
        let version = buffer[4]
        let kindByte = buffer[5]
        let reserved = buffer.uint16(at: 6)
        let length = Int(buffer.uint32(at: 8))
        guard magic == Frame.magic, version == 1, reserved == 0, let kind = FrameKind(rawValue: kindByte) else {
            buffer.removeAll(keepingCapacity: false)
            throw NearError.malformedFrame
        }
        guard length <= maximumPayload else {
            buffer.removeAll(keepingCapacity: false)
            throw NearError.frameTooLarge
        }
        let total = Frame.headerCount + length
        guard buffer.count >= total else { return nil }
        let payload = buffer.subdata(in: Frame.headerCount..<total)
        buffer.removeSubrange(0..<total)
        return Frame(kind: kind, payload: payload)
    }
}

struct ByteReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) {
        self.data = data
    }

    mutating func take(_ count: Int) throws -> Data {
        guard count >= 0, offset &+ count >= offset, offset + count <= data.count else {
            throw NearError.malformedFrame
        }
        let slice = data.subdata(in: offset..<(offset + count))
        offset += count
        return slice
    }

    mutating func uint16() throws -> UInt16 {
        let bytes = try take(2)
        return (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
    }

    func remaining() -> Data {
        guard offset <= data.count else { return Data() }
        return data.subdata(in: offset..<data.count)
    }

    func isEmpty() -> Bool { offset == data.count }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        (UInt16(self[offset]) << 8) | UInt16(self[offset + 1])
    }

    func uint32(at offset: Int) -> UInt32 {
        (UInt32(self[offset]) << 24)
            | (UInt32(self[offset + 1]) << 16)
            | (UInt32(self[offset + 2]) << 8)
            | UInt32(self[offset + 3])
    }

    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(truncatingIfNeeded: value))
    }
}
