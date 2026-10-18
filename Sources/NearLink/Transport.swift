import Foundation

enum Sighting: Sendable, Equatable {
    case discovered(NearPeer)
    case lost(NearPeer.ID)
}

protocol ByteLink: Sendable {
    var id: UUID { get }
    func send(_ data: Data) async throws
    func receive() async throws -> Data
    func close() async
}

protocol NearTransport: Sendable {
    func setIncoming(_ handler: @escaping @Sendable (any ByteLink) -> Void) async
    func start(_ configuration: NearConfiguration) async throws -> AsyncStream<Sighting>
    func stop() async
    func connect(to peerID: NearPeer.ID) async throws -> any ByteLink
}

actor BytePipe {
    private var chunks: [Data] = []
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var closed = false

    func write(_ data: Data) throws {
        if closed { throw NearError.closed }
        if waiters.isEmpty {
            chunks.append(data)
        } else {
            waiters.removeFirst().resume(returning: data)
        }
    }

    func read() async throws -> Data {
        if !chunks.isEmpty { return chunks.removeFirst() }
        if closed { throw NearError.closed }
        return try await withCheckedThrowingContinuation { continuation in
            if closed {
                continuation.resume(throwing: NearError.closed)
            } else {
                waiters.append(continuation)
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(throwing: NearError.closed)
        }
    }
}

struct MemoryLink: ByteLink {
    let id: UUID
    let inbound: BytePipe
    let outbound: BytePipe

    func send(_ data: Data) async throws {
        try await outbound.write(data)
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await inbound.read()
        } onCancel: {
            Task { await inbound.close() }
        }
    }

    func close() async {
        await inbound.close()
        await outbound.close()
    }

    static func pair() -> (local: MemoryLink, remote: MemoryLink) {
        let forward = BytePipe()
        let back = BytePipe()
        return (
            MemoryLink(id: UUID(), inbound: back, outbound: forward),
            MemoryLink(id: UUID(), inbound: forward, outbound: back)
        )
    }
}
