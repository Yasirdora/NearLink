import Foundation
import Network
import os

actor NetworkTransport: NearTransport {
    private let queue = DispatchQueue(label: "NearLink.browser")
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var incoming: (@Sendable (any ByteLink) -> Void)?
    private var endpoints: [UUID: NWEndpoint] = [:]
    private var sightings: AsyncStream<Sighting>.Continuation?
    private var localID: UUID?
    private let logger = Logger(subsystem: "NearLink", category: "network")

    func setIncoming(_ handler: @escaping @Sendable (any ByteLink) -> Void) {
        incoming = handler
    }

    func start(_ configuration: NearConfiguration) async throws -> AsyncStream<Sighting> {
        let (stream, continuation) = AsyncStream.makeStream(of: Sighting.self, bufferingPolicy: .unbounded)
        sightings = continuation
        localID = configuration.identity.id

        let parameters = Self.parameters()
        let listener = try NWListener(using: parameters, on: .any)
        var record = NWTXTRecord()
        record["id"] = configuration.identity.id.uuidString
        record["v"] = "1"
        listener.service = NWListener.Service(
            name: configuration.displayName,
            type: configuration.bonjourType,
            txtRecord: record
        )
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }

        do {
            try await ready(listener)
        } catch {
            listener.cancel()
            sightings = nil
            continuation.finish()
            throw error
        }
        self.listener = listener

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: configuration.bonjourType, domain: nil),
            using: parameters
        )
        let logger = self.logger
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { await self?.apply(results) }
        }
        browser.stateUpdateHandler = { state in
            if case .failed = state {
                logger.error("Browser failed")
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        return stream
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        sightings?.finish()
        listener = nil
        browser = nil
        sightings = nil
        endpoints.removeAll()
    }

    func connect(to peerID: NearPeer.ID) async throws -> any ByteLink {
        guard let endpoint = endpoints[peerID] else { throw NearError.unknownPeer }
        let link = NetworkLink(connection: NWConnection(to: endpoint, using: Self.parameters()))
        try await link.open()
        return link
    }

    private func accept(_ connection: NWConnection) async {
        let link = NetworkLink(connection: connection)
        do {
            try await link.open()
        } catch {
            logger.error("Incoming connection failed")
            await link.close()
            return
        }
        incoming?(link)
    }

    private func ready(_ listener: NWListener) async throws {
        let logger = logger
        let queue = queue
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.succeed(continuation)
                case .waiting, .setup:
                    break
                case .failed:
                    logger.error("Listener failed")
                    gate.fail(continuation, NearError.connectionFailed)
                case .cancelled:
                    gate.fail(continuation, NearError.cancelled)
                @unknown default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    private func apply(_ results: Set<NWBrowser.Result>) {
        let previous = endpoints
        var next: [UUID: NWEndpoint] = [:]
        var peers: [UUID: NearPeer] = [:]
        for result in results {
            guard case .bonjour(let record) = result.metadata,
                  record["v"] == "1",
                  let idString = record["id"],
                  let id = UUID(uuidString: idString),
                  id != localID,
                  case .service(let name, _, _, _) = result.endpoint
            else { continue }
            let displayName = DisplayName.isValid(name) ? name : "Device"
            next[id] = result.endpoint
            peers[id] = NearPeer(id: id, displayName: displayName)
        }

        endpoints = next
        for (id, peer) in peers where previous[id] == nil {
            sightings?.yield(.discovered(peer))
        }
        for id in previous.keys where next[id] == nil {
            sightings?.yield(.lost(id))
        }
    }

    private static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: nil, tcp: tcp)
        parameters.includePeerToPeer = true
        return parameters
    }
}

final class NetworkLink: ByteLink, @unchecked Sendable {
    let id = UUID()
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "NearLink.link")
    private let inbound = BytePipe()
    private let receiveLock = NSLock()
    private var didStartReceive = false

    init(connection: NWConnection) {
        self.connection = connection
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let gate = ResumeOnce()
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.startReading()
                    gate.succeed(continuation)
                case .failed:
                    _ = gate.fail(continuation, NearError.connectionFailed)
                    Task { await self.inbound.close() }
                case .cancelled:
                    _ = gate.fail(continuation, NearError.cancelled)
                    Task { await self.inbound.close() }
                case .setup, .preparing, .waiting:
                    break
                @unknown default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: .defaultMessage,
                isComplete: false,
                completion: .contentProcessed { error in
                    if error == nil {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: NearError.connectionFailed)
                    }
                }
            )
        }
    }

    func receive() async throws -> Data {
        try await withTaskCancellationHandler {
            try await inbound.read()
        } onCancel: {
            Task { await self.inbound.close() }
        }
    }

    func close() async {
        connection.cancel()
        await inbound.close()
    }

    private func startReading() {
        receiveLock.lock()
        let start = !didStartReceive
        didStartReceive = true
        receiveLock.unlock()
        guard start else { return }
        readMore()
    }

    private func readMore() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                Task { try? await self.inbound.write(data) }
            }
            if error != nil || isComplete {
                Task { await self.inbound.close() }
                return
            }
            self.readMore()
        }
    }
}

/// Resumes a start continuation once. Network callbacks can repeat a state.
final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var settled = false

    @discardableResult
    func succeed(_ continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        let first = !settled
        settled = true
        lock.unlock()
        if first { continuation.resume() }
        return first
    }

    @discardableResult
    func fail(_ continuation: CheckedContinuation<Void, Error>, _ error: Error) -> Bool {
        lock.lock()
        let first = !settled
        settled = true
        lock.unlock()
        if first { continuation.resume(throwing: error) }
        return first
    }
}
