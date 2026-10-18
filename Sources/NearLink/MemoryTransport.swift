import Foundation

actor MemoryFabric {
    private struct Slot {
        var peer: NearPeer
        var accept: @Sendable (MemoryLink) -> Void
    }

    private var slots: [UUID: Slot] = [:]
    private var browsers: [UUID: AsyncStream<Sighting>.Continuation] = [:]

    func subscribe(localID: UUID) -> AsyncStream<Sighting> {
        let (stream, continuation) = AsyncStream.makeStream(of: Sighting.self, bufferingPolicy: .unbounded)
        browsers[localID] = continuation
        for (id, slot) in slots where id != localID {
            continuation.yield(.discovered(slot.peer))
        }
        return stream
    }

    func publish(peer: NearPeer, accept: @escaping @Sendable (MemoryLink) -> Void) {
        slots[peer.id] = Slot(peer: peer, accept: accept)
        for (id, continuation) in browsers where id != peer.id {
            continuation.yield(.discovered(peer))
        }
    }

    func withdraw(_ id: UUID) {
        slots[id] = nil
        for (browserID, continuation) in browsers where browserID != id {
            continuation.yield(.lost(id))
        }
        browsers[id]?.finish()
        browsers[id] = nil
    }

    func connect(to id: UUID) throws -> MemoryLink {
        guard let slot = slots[id] else { throw NearError.unknownPeer }
        let ends = MemoryLink.pair()
        slot.accept(ends.remote)
        return ends.local
    }

    /// A device that accepts bytes and never answers. Tests use it for the pairing deadline.
    func advertiseSilentPeer(named name: String) -> NearPeer {
        let peer = NearPeer(id: UUID(), displayName: name)
        publish(peer: peer) { link in
            Task {
                while true {
                    do {
                        _ = try await link.receive()
                    } catch {
                        return
                    }
                }
            }
        }
        return peer
    }
}

actor MemoryTransport: NearTransport {
    private let fabric: MemoryFabric
    private var incoming: (@Sendable (any ByteLink) -> Void)?
    private var localID: UUID?

    init(fabric: MemoryFabric) {
        self.fabric = fabric
    }

    func setIncoming(_ handler: @escaping @Sendable (any ByteLink) -> Void) {
        incoming = handler
    }

    func start(_ configuration: NearConfiguration) async throws -> AsyncStream<Sighting> {
        let id = configuration.identity.id
        localID = id
        let peer = NearPeer(id: id, displayName: configuration.displayName)
        let handler = incoming
        await fabric.publish(peer: peer) { link in
            handler?(link)
        }
        return await fabric.subscribe(localID: id)
    }

    func stop() async {
        guard let localID else { return }
        await fabric.withdraw(localID)
        self.localID = nil
    }

    func connect(to peerID: NearPeer.ID) async throws -> any ByteLink {
        try await fabric.connect(to: peerID)
    }
}
