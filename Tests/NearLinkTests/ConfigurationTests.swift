import Foundation
import Testing
@testable import NearLink

struct ConfigurationTests {
    @Test func serviceTypeIsABonjourLabel() throws {
        let configuration = try sample(service: "Drafts")
        #expect(configuration.serviceType == "drafts")
        #expect(configuration.bonjourType == "_drafts._tcp")
        #expect(throws: NearError.invalidServiceType) { try sample(service: "") }
        #expect(throws: NearError.invalidServiceType) { try sample(service: "-draft") }
        #expect(throws: NearError.invalidServiceType) { try sample(service: "a name") }
        #expect(throws: NearError.invalidServiceType) { try sample(service: "this-name-is-too-long") }
    }

    @Test func passcodeIsFourToEightDigits() throws {
        let code = try NearPasscode("481296")
        #expect(code.code == "481296")
        #expect(code.debugDescription == "NearPasscode(6 digits)")
        #expect(throws: NearError.invalidPasscode) { try NearPasscode("123") }
        #expect(throws: NearError.invalidPasscode) { try NearPasscode("123456789") }
        #expect(throws: NearError.invalidPasscode) { try NearPasscode("12ab") }
        let generated = try NearPasscode.generate()
        #expect(generated.code.count == 6)
        #expect(generated.code.allSatisfy { $0 >= "0" && $0 <= "9" })
    }

    @Test func draftNameIsNotAPath() throws {
        let draft = try Draft(name: "Scene 1", content: Data("INT. ROOM - DAY".utf8))
        #expect(draft.content == Data("INT. ROOM - DAY".utf8))
        #expect(throws: NearError.invalidDraftName) { try Draft(name: "", content: Data()) }
        #expect(throws: NearError.invalidDraftName) { try Draft(name: "../secret", content: Data()) }
        #expect(throws: NearError.invalidDraftName) { try Draft(name: "a/b", content: Data()) }
        #expect(throws: NearError.invalidDraftName) { try Draft(name: ".", content: Data()) }
    }

    @Test func limitsStayInsideARange() throws {
        #expect(throws: NearError.invalidLimit) {
            try sample(maximum: 0)
        }
        #expect(throws: NearError.invalidLimit) {
            try sample(timeout: .milliseconds(10))
        }
        #expect(throws: NearError.invalidDisplayName) {
            try sample(name: "")
        }
    }

    private func sample(
        service: String = "drafts",
        name: String = "Writer's Mac",
        maximum: Int = 1024,
        timeout: Duration = .seconds(10)
    ) throws -> NearConfiguration {
        try NearConfiguration(
            serviceType: service,
            identity: NearIdentity(),
            displayName: name,
            passcode: try NearPasscode("481296"),
            maximumDraftBytes: maximum,
            handshakeTimeout: timeout
        )
    }
}
