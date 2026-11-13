import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/FirmwareModels.cs

// MARK: - Release

/// Release channel of a firmware build. Nightly builds are deliberately not offered.
enum FirmwareChannel: String, Sendable, Codable {
    case stable
    case alpha
    /// A file the user picked locally — no release metadata available.
    case local
}

/// One entry of api.meshtastic.org `github/firmware/list`.
struct FirmwareRelease: Equatable, Hashable, Sendable {
    let id: String
    let title: String
    let pageURL: String
    let zipURL: String
    let releaseNotes: String
    let channel: FirmwareChannel

    /// Version as used in artifact paths and file names ("2.7.26.54e0d8d" for id "v2.7.26.54e0d8d").
    var version: String {
        id.hasPrefix("v") ? String(id.dropFirst()) : id
    }

    /// Numeric `major.minor.patch` prefix (hash suffix dropped), or nil when the id is malformed.
    var numericVersion: FirmwareVersion? {
        FirmwareVersion(version)
    }

    static func localFile(named fileName: String) -> FirmwareRelease {
        FirmwareRelease(id: "local", title: fileName, pageURL: "", zipURL: "", releaseNotes: "", channel: .local)
    }
}

// MARK: - Architecture

/// Chip family of a device, as far as the firmware update needs to know it.
/// The ESP32 family is split per chip because images are chip-specific.
enum FirmwareArchitecture: String, CaseIterable, Sendable {
    case esp32 = "esp32"
    case esp32s2 = "esp32-s2"
    case esp32s3 = "esp32-s3"
    case esp32c2 = "esp32-c2"
    case esp32c3 = "esp32-c3"
    case esp32c6 = "esp32-c6"
    case esp32h2 = "esp32-h2"
    case nrf52840 = "nrf52840"
    case rp2040 = "rp2040"
    case rp2350 = "rp2350"
    case unknown = "unknown"

    /// Parses a catalog `architecture` value ("esp32-s3", "esp32s3", "nrf52840", "rp2040", …).
    /// Anything unrecognised becomes `.unknown`; a bare "esp32…" variant that is not listed stays `.unknown`
    /// rather than being treated as the original ESP32 (different chip ids).
    init(catalogValue: String) {
        let value = catalogValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch value {
        case "esp32": self = .esp32
        case "esp32-s2", "esp32s2": self = .esp32s2
        case "esp32-s3", "esp32s3": self = .esp32s3
        case "esp32-c2", "esp32c2": self = .esp32c2
        case "esp32-c3", "esp32c3": self = .esp32c3
        case "esp32-c6", "esp32c6": self = .esp32c6
        case "esp32-h2", "esp32h2": self = .esp32h2
        default:
            if value.hasPrefix("nrf52") {
                self = .nrf52840
            } else if value.hasPrefix("rp2350") {
                self = .rp2350
            } else if value.hasPrefix("rp2040") {
                self = .rp2040
            } else {
                self = .unknown
            }
        }
    }

    var isEsp32: Bool {
        switch self {
        case .esp32, .esp32s2, .esp32s3, .esp32c2, .esp32c3, .esp32c6, .esp32h2: true
        default: false
        }
    }

    var isNrf52: Bool { self == .nrf52840 }

    var isRp2: Bool { self == .rp2040 || self == .rp2350 }

    /// `esp_chip_id_t` the image header must carry, or nil for non-ESP architectures.
    var espChipId: UInt16? {
        switch self {
        case .esp32: 0x0000
        case .esp32s2: 0x0002
        case .esp32c3: 0x0005
        case .esp32s3: 0x0009
        case .esp32c2: 0x000C
        case .esp32c6: 0x000D
        case .esp32h2: 0x0010
        default: nil
        }
    }

    /// UF2 family ids a file for this architecture may legitimately carry (empty for ESP32 / unknown).
    var uf2FamilyIds: [UInt32] {
        switch self {
        case .nrf52840:
            [UF2Family.nrf52840]
        case .rp2040:
            [UF2Family.rp2040, UF2Family.rp2Absolute]
        case .rp2350:
            [
                UF2Family.rp2350ArmS,
                UF2Family.rp2350RiscV,
                UF2Family.rp2350ArmNs,
                UF2Family.rp2Absolute,
            ]
        default:
            []
        }
    }

    /// Update methods the architecture supports in principle (the device's radios still decide).
    var supportedArtifactKinds: Set<FirmwareArtifactKind> {
        if isEsp32 { return [.espOtaBin] }
        if isNrf52 { return [.nrfOtaZip, .uf2] }
        if isRp2 { return [.uf2] }
        return []
    }
}

// MARK: - Device hardware

/// One entry of api.meshtastic.org `resource/deviceHardware`.
struct DeviceHardware: Equatable, Hashable, Sendable {
    let hwModel: Int
    let hwModelSlug: String
    var platformioTarget: String
    /// Raw catalog value ("esp32-s3", "nrf52840", …); see `firmwareArchitecture`.
    let architecture: String
    let activelySupported: Bool
    let displayName: String
    let requiresDfu: Bool?
    let requiresBootloaderUpgradeForOta: Bool?
    let supportLevel: Int?

    var firmwareArchitecture: FirmwareArchitecture {
        FirmwareArchitecture(catalogValue: architecture)
    }

    var isEsp32: Bool { architecture.lowercased().hasPrefix("esp32") }
    var isNrf52: Bool { architecture.lowercased().hasPrefix("nrf52") }
    var isRp2040: Bool { architecture.lowercased().hasPrefix("rp2") }

    /// Target used in artifact file names; falls back to the slug when the catalog has no PlatformIO target.
    var effectiveTarget: String {
        platformioTarget.isEmpty ? hwModelSlug : platformioTarget
    }

    /// Placeholder for devices the catalog does not know. The `pioEnv` the device reports is the only
    /// handle; the architecture is guessed from the hardware-model name so a path can still be offered.
    static func unknown(hwModel: Int, hwModelName: String, pioEnv: String?, architectureGuess: String) -> DeviceHardware {
        DeviceHardware(
            hwModel: hwModel,
            hwModelSlug: hwModelName,
            platformioTarget: pioEnv ?? "",
            architecture: architectureGuess,
            activelySupported: false,
            displayName: hwModelName,
            requiresDfu: nil,
            requiresBootloaderUpgradeForOta: nil,
            supportLevel: nil
        )
    }
}

// MARK: - Artifacts and methods

/// Which kind of file a firmware update needs.
enum FirmwareArtifactKind: String, CaseIterable, Sendable {
    /// ESP32 application image for Unified OTA (`.bin`).
    case espOtaBin
    /// nRF52 Nordic DFU package for Bluetooth DFU (`-ota.zip`).
    case nrfOtaZip
    /// UF2 image for the USB mass-storage bootloader (nRF52 / RP2040).
    case uf2

    /// Suffix after `firmware-<target>-<version>` of a release artifact, most specific first.
    var fileSuffix: String {
        switch self {
        case .espOtaBin: ".bin"
        case .nrfOtaZip: "-ota.zip"
        case .uf2: ".uf2"
        }
    }

    /// File extension (lower case, with dot) a user-picked file must have.
    var fileExtension: String {
        switch self {
        case .espOtaBin: ".bin"
        case .nrfOtaZip: ".zip"
        case .uf2: ".uf2"
        }
    }
}

/// How the firmware reaches the device.
enum FirmwareUpdateMethod: String, CaseIterable, Sendable {
    /// ESP32 Unified OTA over TCP port 3232 (device must have Wi-Fi configured).
    case wifiOta
    /// ESP32 Unified OTA over the loader's BLE service.
    case bleOta
    /// nRF52 Nordic DFU (Legacy or Secure) over BLE via the Adafruit bootloader.
    case bleDfu
    /// UF2 copy onto the USB mass-storage bootloader drive (nRF52 / RP2040).
    case uf2

    var artifactKind: FirmwareArtifactKind {
        switch self {
        case .wifiOta, .bleOta: .espOtaBin
        case .bleDfu: .nrfOtaZip
        case .uf2: .uf2
        }
    }
}

/// A downloaded or user-supplied firmware file with the hash the OTA loader will check.
struct FirmwareArtifact: Equatable, Sendable {
    let url: URL
    let size: Int
    /// SHA-256 of the whole file (32 bytes).
    let sha256: Data

    var fileName: String { url.lastPathComponent }

    var sha256Hex: String { sha256.map { String(format: "%02x", $0) }.joined() }
}

/// One `files[]` entry of a per-target `.mt.json` manifest (published since firmware 2.7.17).
struct FirmwareManifestFile: Equatable, Sendable {
    let name: String
    let partName: String
    /// Lower- or upper-case hex MD5; empty when the manifest carries none.
    let md5: String
    /// Expected size in bytes; 0 when unknown.
    let bytes: Int
}

// MARK: - Chip identifiers

/// UF2 family ids (UF2 spec `familyID` field) the firmware update knows.
enum UF2Family {
    static let nrf52840: UInt32 = 0xADA5_2840
    static let rp2040: UInt32 = 0xE48B_FF56
    static let rp2Absolute: UInt32 = 0xE48B_FF57
    static let rp2350ArmS: UInt32 = 0xE48B_FF59
    static let rp2350RiscV: UInt32 = 0xE48B_FF5A
    static let rp2350ArmNs: UInt32 = 0xE48B_FF5B

    static func name(_ id: UInt32) -> String {
        switch id {
        case nrf52840: "nRF52840"
        case rp2040: "RP2040"
        case rp2350ArmS: "RP2350 (ARM-S)"
        case rp2350RiscV: "RP2350 (RISC-V)"
        case rp2350ArmNs: "RP2350 (ARM-NS)"
        case rp2Absolute: "RP2 absolute"
        default: String(format: "0x%08X", id)
        }
    }
}

/// `esp_chip_id_t` values of the ESP-IDF image header.
enum EspChip {
    static func name(_ id: UInt16) -> String {
        switch id {
        case 0x0000: "ESP32"
        case 0x0002: "ESP32-S2"
        case 0x0005: "ESP32-C3"
        case 0x0009: "ESP32-S3"
        case 0x000C: "ESP32-C2"
        case 0x000D: "ESP32-C6"
        case 0x0010: "ESP32-H2"
        default: String(format: "0x%04X", id)
        }
    }
}
