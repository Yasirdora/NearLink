# ``NearLink``

Carry one draft between Apple devices on the local network.

## Overview

Both devices share a short pairing code. NearLink does not write that code on the wire. Each connection agrees an ephemeral P-256 key, derives its message key with HKDF-SHA256, and seals the draft with AES-GCM. The receiver checks the seal and the content hash before ``NearEvent/received(_:from:)`` is delivered.

Discovery uses Bonjour through Network.framework, including peer-to-peer Wi-Fi. The app keeps ``NearIdentity``. The package does not store it.

Call ``NearSession/start()``, ``NearSession/connect(_:)``, then ``NearSession/send(_:to:)``. Call ``NearSession/stop()`` when the transfer is done.

## Topics

### Session

- ``NearSession``
- ``NearConfiguration``
- ``NearEvent``
- ``NearError``

### Draft

- ``Draft``
- ``NearPeer``
- ``NearIdentity``
- ``NearPasscode``
