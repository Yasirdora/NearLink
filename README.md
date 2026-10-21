# NearLink

NearLink carries one draft from one Apple device to another on the local network. Both sides share a short pairing code. The code is never written on the wire. A draft is handed to the app only when its seal and its content hash both check.

The session is built on Network.framework and CryptoKit. Discovery is Bonjour, including peer-to-peer Wi-Fi. Each connection makes an ephemeral P-256 key. HKDF-SHA256 mixes that shared secret with the pairing code. Draft bytes are then sealed with AES-GCM. A repeated or reordered frame does not open.

## Requirements

Swift 6. macOS 15, iOS 18, tvOS 18, or visionOS 2.

## Installation

Add the package to the app target.

```swift
.package(url: "https://github.com/Yasirdora/NearLink.git", branch: "main")
```

## Local network

The system asks before an app browses the local network. The Bonjour type is the service type you pass in, with underscores.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Finds a nearby device so you can send a draft.</string>
<key>NSBonjourServices</key>
<array>
    <string>_drafts._tcp</string>
</array>
```

## Send

```swift
let configuration = try NearConfiguration(
    serviceType: "drafts",
    identity: NearIdentity(),
    displayName: "Writer's Mac",
    passcode: try NearPasscode("481296")
)
let session = NearSession(configuration: configuration)
try await session.start()

// `peers()` lists who is nearby. `events` reports the same arrivals.
guard let peer = await session.peers().first else { return }
try await session.connect(peer)
let draft = try Draft(name: "Scene 1", content: Data(text.utf8))
try await session.send(draft, to: peer.id)
```

Keep the `NearIdentity` with the app if this device should keep the same id next time. NearLink does not write it to disk.

The other device uses the same service type and the same code. It reads `.received` from `events`. `connect` returns when pairing has finished. `send` throws if it has not.

Subscribe to `events` before `start` if you need the first `.discovered`. Calling `stop` ends the session.

## Pairing

Show the code on one device and enter it on the other. A mismatch closes the link. Nothing from that attempt is delivered.

The code is short enough to read aloud. Someone who can try values against a live connection can eventually guess it. A recording of the handshake is not enough to test those guesses, because the P-256 shared secret is not in the recording.

## Limits

One send is one draft. The default maximum is 8 MB. A larger draft is refused before it is written to the network.

NearLink does not store drafts, does not retry a failed send, and does not cross the internet.

## Tests

```
swift test
```
