import CryptoKit
import Foundation
import Observation
import Security

enum KioskSecurityError: LocalizedError, Equatable {
    case emptyPassword
    case invalidParameters
    case invalidCredential
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .emptyPassword:
            return String(localized: "Enter a kiosk password.")
        case .invalidParameters:
            return String(localized: "The kiosk security parameters are invalid.")
        case .invalidCredential:
            return String(localized: "The stored kiosk credential is invalid.")
        case .keychain(let status):
            let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            return String(localized: "Keychain error: \(detail)")
        }
    }
}

protocol KioskCredentialStoring: Sendable {
    func loadCredential() throws -> Data?
    func saveCredential(_ data: Data) throws
    func deleteCredential() throws
}

struct KeychainKioskCredentialStore: KioskCredentialStoring {
    private let service: String
    private let account: String

    init(
        service: String = "dev.marcelwolf.MeshHessen.kiosk",
        account: String = "password-verifier-v1"
    ) {
        self.service = service
        self.account = account
    }

    func loadCredential() throws -> Data? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KioskSecurityError.keychain(status) }
        guard let data = item as? Data else { throw KioskSecurityError.invalidCredential }
        return data
    }

    func saveCredential(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw KioskSecurityError.keychain(updateStatus) }

        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KioskSecurityError.keychain(addStatus) }
    }

    func deleteCredential() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KioskSecurityError.keychain(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

protocol KioskPasswordDeriving: Sendable {
    func deriveKey(
        password: String,
        salt: Data,
        iterationCount: Int,
        keyByteCount: Int
    ) throws -> Data
}

struct PBKDF2SHA256PasswordDeriver: KioskPasswordDeriving {
    func deriveKey(
        password: String,
        salt: Data,
        iterationCount: Int,
        keyByteCount: Int
    ) throws -> Data {
        guard iterationCount > 0, keyByteCount > 0 else {
            throw KioskSecurityError.invalidParameters
        }

        let key = SymmetricKey(data: Data(password.utf8))
        let digestByteCount = SHA256.Digest.byteCount
        let blockCount = (keyByteCount + digestByteCount - 1) / digestByteCount
        guard blockCount <= Int(UInt32.max) else { throw KioskSecurityError.invalidParameters }

        var derivedKey = Data()
        derivedKey.reserveCapacity(blockCount * digestByteCount)

        for block in 1...blockCount {
            var input = salt
            var blockIndex = UInt32(block).bigEndian
            withUnsafeBytes(of: &blockIndex) { input.append(contentsOf: $0) }

            var u = Data(HMAC<SHA256>.authenticationCode(for: input, using: key))
            var accumulator = [UInt8](u)

            if iterationCount > 1 {
                for _ in 2...iterationCount {
                    u = Data(HMAC<SHA256>.authenticationCode(for: u, using: key))
                    let bytes = [UInt8](u)
                    for index in accumulator.indices {
                        accumulator[index] ^= bytes[index]
                    }
                }
            }

            derivedKey.append(contentsOf: accumulator)
        }

        return Data(derivedKey.prefix(keyByteCount))
    }
}

protocol KioskSaltGenerating: Sendable {
    func salt(byteCount: Int) throws -> Data
}

struct SecureKioskSaltGenerator: KioskSaltGenerating {
    func salt(byteCount: Int) throws -> Data {
        guard byteCount > 0 else { throw KioskSecurityError.invalidParameters }
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, buffer.count, baseAddress)
        }
        guard status == errSecSuccess else { throw KioskSecurityError.keychain(status) }
        return Data(bytes)
    }
}

private struct KioskPasswordRecord: Codable, Sendable {
    let version: Int
    let iterationCount: Int
    let salt: Data
    let verifier: Data

    func validate() throws {
        guard version == 1,
              (1...1_000_000).contains(iterationCount),
              salt.count >= 16,
              (16...64).contains(verifier.count)
        else {
            throw KioskSecurityError.invalidCredential
        }
    }
}

@Observable
@MainActor
final class KioskState {
    static let shared = KioskState(settings: .shared)

    private(set) var isLocked: Bool
    private(set) var hasPassword: Bool
    private(set) var recoveryRequired: Bool
    private(set) var errorMessage: String?

    private let settings: SettingsService
    private let credentialStore: any KioskCredentialStoring
    private let passwordDeriver: any KioskPasswordDeriving
    private let saltGenerator: any KioskSaltGenerating
    private let iterationCount: Int
    private let keyByteCount: Int

    init(
        settings: SettingsService,
        credentialStore: any KioskCredentialStoring = KeychainKioskCredentialStore(),
        passwordDeriver: any KioskPasswordDeriving = PBKDF2SHA256PasswordDeriver(),
        saltGenerator: any KioskSaltGenerating = SecureKioskSaltGenerator(),
        iterationCount: Int = 100_000,
        keyByteCount: Int = 32
    ) {
        self.settings = settings
        self.credentialStore = credentialStore
        self.passwordDeriver = passwordDeriver
        self.saltGenerator = saltGenerator
        self.iterationCount = iterationCount
        self.keyByteCount = keyByteCount

        let credentialExists = (try? credentialStore.loadCredential()) != nil
        self.hasPassword = credentialExists
        self.recoveryRequired = settings.kioskModeEnabled && !credentialExists
        self.isLocked = settings.kioskModeEnabled && credentialExists
    }

    func setPassword(_ password: String) async throws {
        guard !password.isEmpty else { throw KioskSecurityError.emptyPassword }
        guard iterationCount > 0, keyByteCount > 0 else { throw KioskSecurityError.invalidParameters }

        let salt = try saltGenerator.salt(byteCount: 16)
        let deriver = passwordDeriver
        let rounds = iterationCount
        let outputBytes = keyByteCount
        let verifier = try await Task.detached(priority: .userInitiated) {
            try deriver.deriveKey(
                password: password,
                salt: salt,
                iterationCount: rounds,
                keyByteCount: outputBytes
            )
        }.value

        let record = KioskPasswordRecord(
            version: 1,
            iterationCount: rounds,
            salt: salt,
            verifier: verifier
        )
        try credentialStore.saveCredential(JSONEncoder().encode(record))
        hasPassword = true
        recoveryRequired = false
        errorMessage = nil
    }

    func enable(with password: String) async throws {
        try await setPassword(password)
        settings.kioskModeEnabled = true
        isLocked = true
    }

    func disable() {
        settings.kioskModeEnabled = false
        isLocked = false
        recoveryRequired = false
        errorMessage = nil
    }

    func lock() {
        guard settings.kioskModeEnabled, hasPassword else { return }
        isLocked = true
    }

    @discardableResult
    func unlock(with password: String) async -> Bool {
        do {
            guard let data = try credentialStore.loadCredential() else {
                hasPassword = false
                recoveryRequired = settings.kioskModeEnabled
                isLocked = false
                errorMessage = String(
                    localized: "The kiosk credential is missing. Set a new password to recover kiosk mode."
                )
                return false
            }

            let record = try JSONDecoder().decode(KioskPasswordRecord.self, from: data)
            try record.validate()
            let deriver = passwordDeriver
            let candidate = try await Task.detached(priority: .userInitiated) {
                try deriver.deriveKey(
                    password: password,
                    salt: record.salt,
                    iterationCount: record.iterationCount,
                    keyByteCount: record.verifier.count
                )
            }.value

            guard Self.constantTimeEquals(candidate, record.verifier) else {
                errorMessage = String(localized: "Incorrect kiosk password.")
                return false
            }

            isLocked = false
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func removePassword() throws {
        try credentialStore.deleteCredential()
        hasPassword = false
        isLocked = false
        recoveryRequired = settings.kioskModeEnabled
        errorMessage = nil
    }

    func isFeatureLocked(_ feature: KioskFeatureMask) -> Bool {
        settings.kioskModeEnabled
            && isLocked
            && settings.kioskLockedFeatures.contains(feature)
    }

    /// Effective policy used by Virtual Node while this kiosk session is locked.
    var effectiveVirtualNodeBlockAdmin: Bool {
        settings.virtualNodeBlockAdmin || (settings.kioskModeEnabled && isLocked)
    }

    private static func constantTimeEquals(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }
}
