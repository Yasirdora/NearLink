import Foundation

/// A local session that delivers one whole draft at a time.
///
/// Call `start`, choose a discovered peer, `connect`, then `send`. The pairing
/// code is part of the configuration on both sides. It is not written on the wire.
public actor NearSession {
    public nonisolated let events: AsyncStream<NearEvent>
    public nonisolated let configuration: NearConfiguration

    private let eventsContinuation: AsyncStream<NearEvent>.Continuation
    private let transport: any NearTransport
    private var phase: Phase = .idle
    private var links: [UUID: Link] = [:]
    private var byPeer: [NearPeer.ID: UUID] = [:]
    private var discovered: [NearPeer.ID: NearPeer] = [:]
    private var connectWaiters: [UUID: CheckedContinuation<NearPeer, Error>] = [:]
    private var connecting: Set<NearPeer.ID> = []
    private var browseTask: Task<Void, Never>?
    private var readTasks: [UUID: Task<Void, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]

    private enum Phase {
        case idle
        case running
        case stopped
    }

    private final class Link {
        var handshake: LinkHandshake
        var decoder: FrameDecoder
        let byteLink: any ByteLink
        var open = false
        var ended = false
        var remote: NearPeer?
        let expected: NearPeer.ID?

        init(handshake: LinkHandshake, decoder: FrameDecoder, byteLink: any ByteLink, expected: NearPeer.ID?) {
            self.handshake = handshake
            self.decoder = decoder
            self.byteLink = byteLink
            self.expected = expected
        }
    }

    public init(configuration: NearConfiguration) {
        self.init(configuration: configuration, transport: NetworkTransport())
    }

    init(configuration: NearConfiguration, transport: any NearTransport) {
        self.configuration = configuration
        self.transport = transport
        let (stream, continuation) = AsyncStream<NearEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.eventsContinuation = continuation
    }

    /// Devices currently advertised, not necessarily paired.
    public func peers() -> [NearPeer] {
        discovered.values.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// Devices that have finished pairing.
    public func pairedPeers() -> [NearPeer] {
        links.values.compactMap { link in
            guard link.open else { return nil }
            return link.remote
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    public func start() async throws {
        guard phase != .running else { throw NearError.alreadyRunning }
        phase = .running
        await transport.setIncoming { [weak self] link in
            Task { await self?.accept(link) }
        }
        let sightings: AsyncStream<Sighting>
        do {
            sightings = try await transport.start(configuration)
        } catch {
            phase = .idle
            throw error
        }
        browseTask = Task { [weak self] in
            for await sighting in sightings {
                await self?.apply(sighting)
            }
        }
    }

    public func stop() async {
        guard phase == .running else { return }
        phase = .stopped
        browseTask?.cancel()
        browseTask = nil

        let openLinks = links.values.filter(\.open)
        for link in openLinks {
            if let goodbye = try? link.handshake.sealGoodbye() {
                try? await link.byteLink.send(goodbye)
            }
            if let peer = link.remote {
                eventsContinuation.yield(.disconnected(peer.id))
            }
        }

        let byteLinks = links.values.map(\.byteLink)
        for task in readTasks.values { task.cancel() }
        for task in timeoutTasks.values { task.cancel() }
        readTasks.removeAll()
        timeoutTasks.removeAll()
        links.removeAll()
        byPeer.removeAll()
        connecting.removeAll()

        let waiters = connectWaiters
        connectWaiters.removeAll()
        for waiter in waiters.values {
            waiter.resume(throwing: NearError.cancelled)
        }

        for byteLink in byteLinks {
            await byteLink.close()
        }
        await transport.stop()
    }

    /// Returns when pairing has finished. Throws if the code does not match.
    @discardableResult
    public func connect(_ peer: NearPeer) async throws -> NearPeer {
        guard phase == .running else { throw NearError.notRunning }
        guard discovered[peer.id] != nil else { throw NearError.unknownPeer }
        if let existing = byPeer[peer.id], let link = links[existing] {
            if link.open, let remote = link.remote { return remote }
            throw NearError.alreadyInProgress
        }
        if connecting.contains(peer.id) { throw NearError.alreadyInProgress }
        connecting.insert(peer.id)

        let byteLink: any ByteLink
        do {
            byteLink = try await transport.connect(to: peer.id)
        } catch {
            connecting.remove(peer.id)
            throw error
        }
        return try await withCheckedThrowingContinuation { continuation in
            connectWaiters[byteLink.id] = continuation
            Task { await self.begin(byteLink, expecting: peer.id) }
        }
    }

    public func send(_ draft: Draft, to peerID: NearPeer.ID) async throws {
        guard phase == .running else { throw NearError.notRunning }
        guard draft.content.count <= configuration.maximumDraftBytes else { throw NearError.draftTooLarge }
        guard let id = byPeer[peerID], let link = links[id], link.open else { throw NearError.notPaired }
        let bytes = try link.handshake.sealDraft(draft)
        try await link.byteLink.send(bytes)
    }

    private func accept(_ byteLink: any ByteLink) async {
        guard phase == .running else {
            await byteLink.close()
            return
        }
        await begin(byteLink, expecting: nil)
    }

    private func begin(_ byteLink: any ByteLink, expecting: NearPeer.ID?) async {
        let handshake: LinkHandshake
        do {
            handshake = try LinkHandshake(
                identity: configuration.identity,
                displayName: configuration.displayName,
                passcode: configuration.passcode,
                maximumDraftBytes: configuration.maximumDraftBytes,
                expecting: expecting
            )
        } catch let error as NearError {
            if let expecting { connecting.remove(expecting) }
            finish(byteLink.id, .failure(error))
            eventsContinuation.yield(.failed(error))
            await byteLink.close()
            return
        } catch {
            if let expecting { connecting.remove(expecting) }
            finish(byteLink.id, .failure(NearError.entropyUnavailable))
            eventsContinuation.yield(.failed(.entropyUnavailable))
            await byteLink.close()
            return
        }

        let link = Link(
            handshake: handshake,
            decoder: FrameDecoder(maximumPayload: configuration.framePayloadCeiling),
            byteLink: byteLink,
            expected: expecting
        )
        let hello = link.handshake.openingFrame()
        links[byteLink.id] = link
        if let expecting {
            byPeer[expecting] = byteLink.id
        }
        startReading(byteLink)
        armTimeout(byteLink.id)
        do {
            try await byteLink.send(hello)
        } catch {
            fail(byteLink.id, .connectionFailed)
        }
    }

    private func apply(_ sighting: Sighting) {
        switch sighting {
        case .discovered(let peer):
            guard peer.id != configuration.identity.id else { return }
            guard discovered[peer.id] == nil else { return }
            discovered[peer.id] = peer
            eventsContinuation.yield(.discovered(peer))
        case .lost(let id):
            guard discovered.removeValue(forKey: id) != nil else { return }
            eventsContinuation.yield(.lost(id))
        }
    }

    private func startReading(_ byteLink: any ByteLink) {
        let id = byteLink.id
        readTasks[id] = Task { [weak self] in
            guard let self else { return }
            do {
                while !Task.isCancelled {
                    let chunk = try await byteLink.receive()
                    await self.ingest(id, chunk)
                }
            } catch {
                await self.linkClosed(id, error)
            }
        }
    }

    private func armTimeout(_ id: UUID) {
        let timeout = configuration.handshakeTimeout
        timeoutTasks[id] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            await self?.timedOut(id)
        }
    }

    private func timedOut(_ id: UUID) {
        guard let link = links[id], !link.open, !link.ended else { return }
        fail(id, .timedOut)
    }

    private func ingest(_ id: UUID, _ chunk: Data) async {
        guard let link = links[id], !link.ended else { return }
        let frames: [Frame]
        do {
            frames = try link.decoder.append(chunk)
        } catch let error as NearError {
            fail(id, error)
            return
        } catch {
            fail(id, .malformedFrame)
            return
        }
        for frame in frames {
            guard let current = links[id], !current.ended else { return }
            let effect = current.handshake.receive(frame)
            current.remote = current.handshake.remote ?? current.remote
            await apply(effect, to: id)
        }
    }

    private func apply(_ effect: HandshakeEffect, to id: UUID) async {
        switch effect {
        case .send(let bytes):
            guard let link = links[id] else { return }
            do {
                try await link.byteLink.send(bytes)
            } catch {
                fail(id, .connectionFailed)
            }
        case .paired(let peer):
            guard let link = links[id], !link.ended else { return }
            link.open = true
            link.remote = peer
            byPeer[peer.id] = id
            discovered[peer.id] = peer
            timeoutTasks[id]?.cancel()
            timeoutTasks[id] = nil
            eventsContinuation.yield(.paired(peer))
            connecting.remove(peer.id)
            finish(id, .success(peer))
        case .draft(let draft):
            guard let link = links[id], link.open, let peer = link.remote else {
                fail(id, .malformedFrame)
                return
            }
            eventsContinuation.yield(.received(draft, from: peer.id))
        case .goodbye:
            close(id)
        case .failed(let error):
            fail(id, error)
        }
    }

    private func fail(_ id: UUID, _ error: NearError) {
        guard let link = links[id], !link.ended else { return }
        link.ended = true
        let peerID = link.remote?.id ?? link.expected
        let byteLink = link.byteLink
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        readTasks[id]?.cancel()
        readTasks[id] = nil
        if let peerID {
            byPeer[peerID] = nil
            connecting.remove(peerID)
        }
        links[id] = nil
        let rejected = error == .pairingFailed || error == .timedOut || error == .unexpectedPeer
        if rejected, let peerID {
            eventsContinuation.yield(.rejected(peerID))
        } else {
            eventsContinuation.yield(.failed(error))
        }
        finish(id, .failure(error))
        Task { await byteLink.close() }
    }

    private func close(_ id: UUID) {
        guard let link = links[id], !link.ended else { return }
        link.ended = true
        let peerID = link.remote?.id
        let wasOpen = link.open
        let byteLink = link.byteLink
        timeoutTasks[id]?.cancel()
        timeoutTasks[id] = nil
        readTasks[id]?.cancel()
        readTasks[id] = nil
        if let peerID {
            byPeer[peerID] = nil
        }
        links[id] = nil
        if wasOpen, let peerID {
            eventsContinuation.yield(.disconnected(peerID))
        } else {
            finish(id, .failure(NearError.closed))
        }
        Task { await byteLink.close() }
    }

    private func linkClosed(_ id: UUID, _ error: Error) {
        guard links[id] != nil else { return }
        if let near = error as? NearError, near == .closed || near == .cancelled {
            close(id)
            return
        }
        fail(id, (error as? NearError) ?? .connectionFailed)
    }

    private func finish(_ id: UUID, _ result: Result<NearPeer, Error>) {
        guard let waiter = connectWaiters.removeValue(forKey: id) else { return }
        waiter.resume(with: result)
    }
}
