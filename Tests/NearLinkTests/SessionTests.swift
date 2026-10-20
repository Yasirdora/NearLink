import Foundation
import Testing
@testable import NearLink

struct SessionTests {
    @Test func twoDevicesExchangeOneDraft() async throws {
        let fabric = MemoryFabric()
        let code = try NearPasscode("481296")
        let mac = try makeSession(name: "Writer's Mac", fabric: fabric, code: code)
        let phone = try makeSession(name: "Writer's iPhone", fabric: fabric, code: code)
        let inbox = Inbox()
        await inbox.watch(phone.events)
        try await mac.start()
        try await phone.start()
        let peer = try await waitForPeer(mac, id: phone.configuration.identity.id)
        let paired = try await mac.connect(peer)
        #expect(paired.displayName == "Writer's iPhone")
        let draft = try Draft(name: "Scene 1", content: Data("INT. ROOM - DAY".utf8))
        try await mac.send(draft, to: paired.id)
        let received = try await inbox.nextDraft()
        #expect(received == draft)
        #expect(await mac.peers().contains { $0.id == mac.configuration.identity.id } == false)
        await mac.stop()
        await phone.stop()
    }

    @Test func aWrongCodeDeliversNothing() async throws {
        let fabric = MemoryFabric()
        let mac = try makeSession(name: "Mac", fabric: fabric, code: try NearPasscode("481296"))
        let phone = try makeSession(name: "iPhone", fabric: fabric, code: try NearPasscode("000000"))
        let inbox = Inbox()
        await inbox.watch(phone.events)
        try await mac.start()
        try await phone.start()
        let peer = try await waitForPeer(mac, id: phone.configuration.identity.id)
        await #expect(throws: NearError.pairingFailed) {
            try await mac.connect(peer)
        }
        try await Task.sleep(for: .milliseconds(50))
        #expect(await inbox.drafts.isEmpty)
        await mac.stop()
        await phone.stop()
    }

    @Test func aSilentDeviceHitsTheDeadline() async throws {
        let fabric = MemoryFabric()
        let session = try makeSession(
            name: "Mac",
            fabric: fabric,
            code: try NearPasscode("481296"),
            timeout: .milliseconds(200)
        )
        let ghost = await fabric.advertiseSilentPeer(named: "Ghost")
        try await session.start()
        _ = try await waitForPeer(session, id: ghost.id)
        let started = ContinuousClock().now
        await #expect(throws: NearError.timedOut) {
            try await session.connect(ghost)
        }
        #expect(ContinuousClock().now - started < .seconds(2))
        await session.stop()
    }

    @Test func anOversizedDraftIsRefusedBeforeItIsSent() async throws {
        let fabric = MemoryFabric()
        let code = try NearPasscode("481296")
        let mac = try makeSession(name: "Mac", fabric: fabric, code: code, maximum: 32)
        let phone = try makeSession(name: "iPhone", fabric: fabric, code: code, maximum: 32)
        try await mac.start()
        try await phone.start()
        let peer = try await waitForPeer(mac, id: phone.configuration.identity.id)
        try await mac.connect(peer)
        let draft = try Draft(name: "Too big", content: Data(repeating: 1, count: 33))
        await #expect(throws: NearError.draftTooLarge) {
            try await mac.send(draft, to: peer.id)
        }
        await mac.stop()
        await phone.stop()
    }

    private func makeSession(
        name: String,
        fabric: MemoryFabric,
        code: NearPasscode,
        maximum: Int = 1024,
        timeout: Duration = .seconds(2)
    ) throws -> NearSession {
        let configuration = try NearConfiguration(
            serviceType: "drafts",
            identity: NearIdentity(),
            displayName: name,
            passcode: code,
            maximumDraftBytes: maximum,
            handshakeTimeout: timeout
        )
        return NearSession(configuration: configuration, transport: MemoryTransport(fabric: fabric))
    }

    private func waitForPeer(_ session: NearSession, id: UUID) async throws -> NearPeer {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while clock.now < deadline {
            if let peer = await session.peers().first(where: { $0.id == id }) {
                return peer
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw NearError.timedOut
    }
}

private actor Inbox {
    private(set) var drafts: [Draft] = []
    private var waiters: [CheckedContinuation<Draft, Error>] = []

    func watch(_ events: AsyncStream<NearEvent>) {
        Task {
            for await event in events {
                guard case .received(let draft, _) = event else { continue }
                if waiters.isEmpty {
                    drafts.append(draft)
                } else {
                    waiters.removeFirst().resume(returning: draft)
                }
            }
        }
    }

    func nextDraft() async throws -> Draft {
        if !drafts.isEmpty { return drafts.removeFirst() }
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
