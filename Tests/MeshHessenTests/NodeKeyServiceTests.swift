import Foundation
import Testing

@testable import MeshHessen

@Suite("Node Public Key Decisions")
struct NodeKeyServiceTests {
    @Test("Ask policy keeps the old key until the user accepts")
    func askAndAccept() throws {
        let fixture = try Fixture(policy: .ask)
        defer { fixture.cleanup() }
        let oldKey = Data(repeating: 0x11, count: 32)
        let newKey = Data(repeating: 0x22, count: 32)

        #expect(fixture.service.checkAndUpdate(
            nodeId: 42,
            shortName: "old",
            longName: "Old Node",
            publicKey: oldKey
        ) == .newEntry)

        let result = fixture.service.checkAndUpdate(
            nodeId: 42,
            shortName: "new",
            longName: "New Node",
            publicKey: newKey
        )
        guard case .mismatchPending(let mismatch) = result else {
            Issue.record("Expected a pending mismatch")
            return
        }

        #expect(fixture.service.publicKey(for: 42) == oldKey)
        #expect(fixture.service.resolve(mismatch, acceptNewKey: true))
        #expect(fixture.service.publicKey(for: 42) == newKey)
    }

    @Test("Rejecting a pending key change preserves the trusted key")
    func askAndReject() throws {
        let fixture = try Fixture(policy: .ask)
        defer { fixture.cleanup() }
        let oldKey = Data(repeating: 0x33, count: 32)
        let newKey = Data(repeating: 0x44, count: 32)
        _ = fixture.service.checkAndUpdate(
            nodeId: 7,
            shortName: "node",
            longName: "Node",
            publicKey: oldKey
        )

        let result = fixture.service.checkAndUpdate(
            nodeId: 7,
            shortName: "node",
            longName: "Node",
            publicKey: newKey
        )
        let mismatch: NodeKeyMismatch
        if case .mismatchPending(let value) = result {
            mismatch = value
        } else {
            Issue.record("Expected a pending mismatch")
            return
        }

        #expect(fixture.service.resolve(mismatch, acceptNewKey: false))
        #expect(fixture.service.publicKey(for: 7) == oldKey)
    }

    @Test("Warn and overwrite policies remain deterministic")
    func automaticPolicies() throws {
        let oldKey = Data(repeating: 0x55, count: 32)
        let newKey = Data(repeating: 0x66, count: 32)

        let warningFixture = try Fixture(policy: .warn)
        defer { warningFixture.cleanup() }
        _ = warningFixture.service.checkAndUpdate(
            nodeId: 1,
            shortName: "warn",
            longName: "Warn",
            publicKey: oldKey
        )
        #expect(warningFixture.service.checkAndUpdate(
            nodeId: 1,
            shortName: "warn",
            longName: "Warn",
            publicKey: newKey
        ) == .mismatchWarned)
        #expect(warningFixture.service.publicKey(for: 1) == oldKey)

        let overwriteFixture = try Fixture(policy: .overwrite)
        defer { overwriteFixture.cleanup() }
        _ = overwriteFixture.service.checkAndUpdate(
            nodeId: 2,
            shortName: "overwrite",
            longName: "Overwrite",
            publicKey: oldKey
        )
        #expect(overwriteFixture.service.checkAndUpdate(
            nodeId: 2,
            shortName: "overwrite",
            longName: "Overwrite",
            publicKey: newKey
        ) == .mismatchOverwritten)
        #expect(overwriteFixture.service.publicKey(for: 2) == newKey)
    }

    private final class Fixture {
        let directory: URL
        let service: NodeKeyService

        init(policy: NodeKeyMismatchPolicy) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("node-key-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            service = NodeKeyService(
                csvURL: directory.appendingPathComponent("keys.csv"),
                policyProvider: { policy }
            )
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
