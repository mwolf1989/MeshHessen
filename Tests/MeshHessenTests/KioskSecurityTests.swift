import Foundation
import Testing

@testable import MeshHessen

@Suite("Kiosk Security")
struct KioskSecurityTests {
    @Test("PBKDF2-HMAC-SHA256 matches the published test vector")
    func pbkdf2Vector() throws {
        let result = try PBKDF2SHA256PasswordDeriver().deriveKey(
            password: "password",
            salt: Data("salt".utf8),
            iterationCount: 2,
            keyByteCount: 32
        )
        #expect(result.hexString == "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43")
    }

    @Test("Kiosk credentials use 100,000 rounds and never store plaintext", .timeLimit(.minutes(1)))
    @MainActor
    func passwordStorage() async throws {
        let defaults = try IsolatedKioskDefaults()
        defer { defaults.cleanUp() }
        let settings = SettingsService(defaults: defaults.defaults)
        let store = InMemoryKioskCredentialStore()
        let deriver = RecordingKioskDeriver()
        let state = KioskState(
            settings: settings,
            credentialStore: store,
            passwordDeriver: deriver,
            saltGenerator: FixedKioskSaltGenerator()
        )

        try await state.setPassword("very-secret")

        #expect(deriver.lastIterationCount == 100_000)
        let storedCredential = try store.loadCredential()
        let stored = try #require(storedCredential)
        #expect(!String(decoding: stored, as: UTF8.self).contains("very-secret"))
        #expect(defaults.defaults.string(forKey: "kioskPassword") == nil)
        #expect(state.hasPassword)
    }

    @Test("An enabled kiosk station starts locked and verifies without timing-sensitive comparison")
    @MainActor
    func lockAndUnlock() async throws {
        let defaults = try IsolatedKioskDefaults()
        defer { defaults.cleanUp() }
        let settings = SettingsService(defaults: defaults.defaults)
        let store = InMemoryKioskCredentialStore()
        let configuration = KioskState(
            settings: settings,
            credentialStore: store,
            saltGenerator: FixedKioskSaltGenerator(),
            iterationCount: 2
        )
        try await configuration.setPassword("correct horse")
        settings.kioskModeEnabled = true

        let restored = KioskState(
            settings: settings,
            credentialStore: store,
            saltGenerator: FixedKioskSaltGenerator(),
            iterationCount: 2
        )
        #expect(restored.isLocked)
        #expect(restored.effectiveVirtualNodeBlockAdmin)
        let rejected = await restored.unlock(with: "wrong")
        #expect(!rejected)
        #expect(restored.isLocked)
        let accepted = await restored.unlock(with: "correct horse")
        #expect(accepted)
        #expect(!restored.isLocked)
        #expect(!restored.effectiveVirtualNodeBlockAdmin)
    }

    @Test("A missing Keychain credential enters recoverable unlocked state")
    @MainActor
    func missingCredentialRecovery() throws {
        let defaults = try IsolatedKioskDefaults()
        defer { defaults.cleanUp() }
        let settings = SettingsService(defaults: defaults.defaults)
        settings.kioskModeEnabled = true

        let state = KioskState(settings: settings, credentialStore: InMemoryKioskCredentialStore())

        #expect(state.recoveryRequired)
        #expect(!state.isLocked)
        #expect(!state.hasPassword)
    }
}

private final class InMemoryKioskCredentialStore: KioskCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var credential: Data?

    func loadCredential() throws -> Data? {
        lock.withLock { credential }
    }

    func saveCredential(_ data: Data) throws {
        lock.withLock { credential = data }
    }

    func deleteCredential() throws {
        lock.withLock { credential = nil }
    }
}

private struct FixedKioskSaltGenerator: KioskSaltGenerating {
    func salt(byteCount: Int) throws -> Data {
        Data(repeating: 0xA5, count: byteCount)
    }
}

private final class RecordingKioskDeriver: KioskPasswordDeriving, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedIterationCount: Int?

    var lastIterationCount: Int? {
        lock.withLock { recordedIterationCount }
    }

    func deriveKey(
        password: String,
        salt: Data,
        iterationCount: Int,
        keyByteCount: Int
    ) throws -> Data {
        lock.withLock { recordedIterationCount = iterationCount }
        return Data(repeating: 0x5A, count: keyByteCount)
    }
}

private struct IsolatedKioskDefaults {
    let suiteName: String
    let defaults: UserDefaults

    init() throws {
        suiteName = "KioskSecurityTests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
