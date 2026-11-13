import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/FirmwareFileInspector.cs

/// Outcome of the pre-flight check of a firmware file. Any `error` item blocks the update.
struct FirmwareInspection: Sendable {
    enum Level: Sendable {
        case info
        case warning
        case error
    }

    enum Item: Equatable, Sendable {
        case wrongExtension(expected: String)
        case factoryImage
        /// File-system, OTA-loader or other non-application image recognised by its name.
        case notApplicationFile(String)
        case kindNotSupported(kind: FirmwareArtifactKind, architecture: FirmwareArchitecture)
        case noTarget
        case nameMismatch(target: String)
        case nameOk(target: String)
        case unreadable(String)
        case notEspImage
        /// ESP image without application descriptor: a bootloader, merged or factory image.
        case notAppImage
        case chipUnverified(found: String)
        case chipMismatch(found: String, expected: String)
        case chipOk(String)
        case embeddedVersion(version: String, project: String?)
        case notUf2
        case uf2NoFamily
        case dfuOk(binFile: String, size: Int)
        case dfuSecureInit
        case dfuInvalid(String)
        /// A self-built image (PlatformIO writes plain `firmware.bin`) whose container checks out.
        case customBuildHint

        var level: Level {
            switch self {
            case .wrongExtension, .factoryImage, .notApplicationFile, .kindNotSupported, .unreadable,
                 .notEspImage, .notAppImage, .chipMismatch, .notUf2, .dfuInvalid:
                .error
            case .noTarget, .nameMismatch, .chipUnverified, .uf2NoFamily:
                .warning
            case .nameOk, .chipOk, .embeddedVersion, .dfuOk, .dfuSecureInit, .customBuildHint:
                .info
            }
        }

        var message: String {
            switch self {
            case .wrongExtension(let expected):
                String(localized: "Wrong file type: a \(expected) file is required.")
            case .factoryImage:
                String(localized: "This is a factory image (full flash). Only the application image may be used for an update.")
            case .notApplicationFile(let name):
                String(localized: "“\(name)” is not a firmware application image.")
            case .kindNotSupported(let kind, let architecture):
                String(localized: "A \(kind.fileExtension) file cannot be used for a \(architecture.rawValue) device.")
            case .noTarget:
                String(localized: "The device's build target is unknown; the file name cannot be checked.")
            case .nameMismatch(let target):
                String(localized: "The file name does not match the device target “\(target)”.")
            case .nameOk(let target):
                String(localized: "File name matches the device target “\(target)”.")
            case .unreadable(let reason):
                String(localized: "The file cannot be read: \(reason)")
            case .notEspImage:
                String(localized: "The file is not an ESP32 firmware image.")
            case .notAppImage:
                String(localized: "The file is a bootloader or factory image, not an application image.")
            case .chipUnverified(let found):
                String(localized: "Image is for \(found); the device's chip could not be verified.")
            case .chipMismatch(let found, let expected):
                String(localized: "Image is for \(found), but the device has \(expected).")
            case .chipOk(let chip):
                String(localized: "Image chip matches the device (\(chip)).")
            case .embeddedVersion(let version, let project):
                String(localized: "Embedded version \(version) (\(project ?? "?")).")
            case .notUf2:
                String(localized: "The file is not a UF2 image.")
            case .uf2NoFamily:
                String(localized: "The UF2 file declares no chip family; it cannot be verified.")
            case .dfuOk(let binFile, let size):
                String(localized: "DFU package OK: \(binFile), \(size) bytes.")
            case .dfuSecureInit:
                String(localized: "The DFU package uses a signed (Secure DFU) init packet.")
            case .dfuInvalid(let reason):
                String(localized: "Invalid DFU package: \(reason)")
            case .customBuildHint:
                String(localized: "This looks like a self-built image; the file content matches the device.")
            }
        }
    }

    let items: [Item]
    /// Version embedded in the image (ESP32) or, failing that, taken from the file name.
    let detectedVersion: String?
    /// Chip the image is built for ("ESP32-S3", "nRF52840", …), when the format declares it.
    let detectedChip: String?

    var hasErrors: Bool { items.contains { $0.level == .error } }
    var errors: [String] { messages(for: .error) }
    var warnings: [String] { messages(for: .warning) }
    var notes: [String] { messages(for: .info) }

    private func messages(for level: Level) -> [String] {
        items.filter { $0.level == level }.map(\.message)
    }
}

/// Pure plausibility checks on firmware files before anything is sent to a device: file name ↔ target,
/// container magic, ESP image chip id ↔ architecture, UF2 family id ↔ architecture, DFU manifest sanity.
/// None of these can prove a file is right, but each catches the classic "wrong board / wrong kind of
/// image" mistake.
enum FirmwareFileInspector {
    // MARK: - File name

    /// Name prefixes of images that are never the application (file system, OTA loader).
    private static let nonApplicationPrefixes = ["littlefs-", "bleota", "mt-"]

    /// True when the leaf name is a file-system / loader image or a factory image.
    static func isNonApplicationFileName(_ fileName: String) -> Bool {
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        let leaf = (normalized.split(separator: "/").last.map(String.init) ?? normalized).lowercased()
        return nonApplicationPrefixes.contains { leaf.hasPrefix($0) }
            || normalized.lowercased().contains(".factory.")
    }

    /// Port of the Android check: the name must carry the exact target followed by a dotted version,
    /// the literal "firmware" or the extension itself, so sibling variants (tlora-v2 vs tlora-v2-1-1_6)
    /// never match.
    static func isValidFirmwareFileName(_ fileName: String, target: String, fileExtension: String) -> Bool {
        let normalized = fileName.replacingOccurrences(of: "\\", with: "/")
        guard !isNonApplicationFileName(normalized),
              !target.trimmingCharacters(in: .whitespaces).isEmpty,
              normalized.lowercased().hasSuffix(fileExtension.lowercased()) else {
            return false
        }
        let targetToken = NSRegularExpression.escapedPattern(for: target)
        let extensionToken = NSRegularExpression.escapedPattern(for: fileExtension)
        let versionOrFirmware = #"([\-_]v?\d+\.\d+|[\-_.]firmware)"#
        let pattern = "^(^|.*[\\-_])\(targetToken)(\(versionOrFirmware).*\(extensionToken)$|\(extensionToken)$)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(normalized.startIndex..., in: normalized)
        return regex.firstMatch(in: normalized, range: range) != nil
    }

    /// Version embedded in a release file name ("firmware-heltec-v3-2.7.26.54e0d8d.bin" → "2.7.26.54e0d8d").
    static func versionFromFileName(_ fileName: String) -> String? {
        let leaf = (fileName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
        let pattern = #"(?:^|[-_])v?(\d+(?:\.[0-9A-Za-z]+)+)(?=(?:[-_][A-Za-z]+)?\.[^.]+$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: leaf, range: NSRange(leaf.startIndex..., in: leaf)),
              let range = Range(match.range(at: 1), in: leaf) else {
            return nil
        }
        return String(leaf[range])
    }

    // MARK: - UF2

    static let uf2MagicStart0: UInt32 = 0x0A32_4655
    static let uf2MagicStart1: UInt32 = 0x9E5D_5157
    static let uf2FlagFamilyId: UInt32 = 0x0000_2000

    static func isUF2(_ bytes: Data) -> Bool {
        bytes.count >= 512
            && bytes.uint32LE(at: 0) == uf2MagicStart0
            && bytes.uint32LE(at: 4) == uf2MagicStart1
    }

    /// Family id declared by the first block, or nil when the file is not UF2 or declares none.
    static func uf2FamilyId(_ bytes: Data) -> UInt32? {
        guard isUF2(bytes), let flags = bytes.uint32LE(at: 8), flags & uf2FlagFamilyId != 0 else { return nil }
        return bytes.uint32LE(at: 28)
    }

    static func uf2FirstTargetAddress(_ bytes: Data) -> UInt32? {
        isUF2(bytes) ? bytes.uint32LE(at: 12) : nil
    }

    // MARK: - ESP32 application image

    static let espImageMagic: UInt8 = 0xE9
    static let espAppDescriptorMagic: UInt32 = 0xABCD_5432
    private static let espAppDescriptorOffset = 0x20

    /// `esp_image_header_t.chip_id` (UInt16 LE at offset 12), or nil when the file is no ESP image.
    static func espImageChipId(_ bytes: Data) -> UInt16? {
        guard bytes.count >= 24, bytes[bytes.startIndex] == espImageMagic else { return nil }
        let low = UInt16(bytes[bytes.startIndex + 12])
        let high = UInt16(bytes[bytes.startIndex + 13])
        return low | high << 8
    }

    /// True when an `esp_app_desc_t` follows the first segment header — an application image, not a
    /// bootloader/merged/factory image (which also starts with 0xE9 but has no app descriptor).
    static func hasEspAppDescriptor(_ bytes: Data) -> Bool {
        bytes.uint32LE(at: espAppDescriptorOffset) == espAppDescriptorMagic
    }

    /// `esp_app_desc_t.version` (32-byte C string at 0x30), or nil.
    static func espAppVersion(_ bytes: Data) -> String? {
        hasEspAppDescriptor(bytes) ? cString(bytes, offset: espAppDescriptorOffset + 16, length: 32) : nil
    }

    /// `esp_app_desc_t.project_name` (32-byte C string at 0x50), or nil.
    static func espAppProjectName(_ bytes: Data) -> String? {
        hasEspAppDescriptor(bytes) ? cString(bytes, offset: espAppDescriptorOffset + 48, length: 32) : nil
    }

    // MARK: - Combined check

    /// Inspects a local file for a device architecture and artifact kind. Reads only the first 4 KB for
    /// header checks; DFU zips are parsed fully. `target` is the device's build target (PlatformIO env).
    static func inspect(
        fileURL: URL,
        expected: FirmwareArchitecture,
        kind: FirmwareArtifactKind,
        target: String? = nil
    ) -> FirmwareInspection {
        var items: [FirmwareInspection.Item] = []
        let name = fileURL.lastPathComponent
        let fileExtension = "." + fileURL.pathExtension.lowercased()
        let versionFromName = versionFromFileName(name)

        guard fileExtension == kind.fileExtension else {
            items.append(.wrongExtension(expected: kind.fileExtension))
            return FirmwareInspection(items: items, detectedVersion: versionFromName, detectedChip: nil)
        }
        if expected != .unknown, !expected.supportedArtifactKinds.contains(kind) {
            items.append(.kindNotSupported(kind: kind, architecture: expected))
        }
        if name.lowercased().contains(".factory.") {
            items.append(.factoryImage)
        } else if isNonApplicationFileName(name) {
            items.append(.notApplicationFile(name))
        }

        var nameMismatch = false
        let trimmedTarget = target?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmedTarget.isEmpty {
            items.append(.noTarget)
        } else if isValidFirmwareFileName(name, target: trimmedTarget, fileExtension: kind.fileSuffix) {
            items.append(.nameOk(target: trimmedTarget))
        } else {
            nameMismatch = true
            items.append(.nameMismatch(target: trimmedTarget))
        }

        let head: Data
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            head = try handle.read(upToCount: 4096) ?? Data()
        } catch {
            items.append(.unreadable(error.localizedDescription))
            return FirmwareInspection(items: items, detectedVersion: versionFromName, detectedChip: nil)
        }

        var detectedVersion = versionFromName
        var detectedChip: String?
        switch kind {
        case .espOtaBin:
            guard let chip = espImageChipId(head) else {
                items.append(.notEspImage)
                break
            }
            detectedChip = EspChip.name(chip)
            if !hasEspAppDescriptor(head) {
                items.append(.notAppImage)
            }
            if let expectedChip = expected.espChipId {
                items.append(
                    expectedChip == chip
                        ? .chipOk(EspChip.name(chip))
                        : .chipMismatch(found: EspChip.name(chip), expected: EspChip.name(expectedChip))
                )
            } else if expected == .unknown {
                items.append(.chipUnverified(found: EspChip.name(chip)))
            }
            if let version = espAppVersion(head), !version.isEmpty {
                detectedVersion = version
                items.append(.embeddedVersion(version: version, project: espAppProjectName(head)))
            }
        case .uf2:
            guard isUF2(head) else {
                items.append(.notUf2)
                break
            }
            guard let family = uf2FamilyId(head) else {
                items.append(.uf2NoFamily)
                break
            }
            detectedChip = UF2Family.name(family)
            let allowed = expected.uf2FamilyIds
            if allowed.isEmpty {
                if expected == .unknown {
                    items.append(.chipUnverified(found: UF2Family.name(family)))
                }
            } else if allowed.contains(family) {
                items.append(.chipOk(UF2Family.name(family)))
            } else {
                items.append(.chipMismatch(found: UF2Family.name(family), expected: UF2Family.name(allowed[0])))
            }
        case .nrfOtaZip:
            do {
                let package = try DfuPackage(zipURL: fileURL)
                items.append(.dfuOk(binFile: package.binFileName, size: package.applicationBinary.count))
                if package.hasSecureInitPacket {
                    items.append(.dfuSecureInit)
                }
            } catch {
                items.append(.dfuInvalid(error.localizedDescription))
            }
        }

        let inspection = FirmwareInspection(items: items, detectedVersion: detectedVersion, detectedChip: detectedChip)
        if nameMismatch, !inspection.hasErrors {
            return FirmwareInspection(
                items: items + [.customBuildHint],
                detectedVersion: detectedVersion,
                detectedChip: detectedChip
            )
        }
        return inspection
    }

    // MARK: - Private

    private static func cString(_ bytes: Data, offset: Int, length: Int) -> String? {
        guard bytes.count >= offset + length else { return nil }
        let start = bytes.startIndex + offset
        let field = bytes[start..<(start + length)]
        let end = field.firstIndex(of: 0) ?? field.endIndex
        return String(decoding: field[field.startIndex..<end], as: UTF8.self)
    }
}

private extension Data {
    func uint32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, count >= offset + 4 else { return nil }
        let base = startIndex + offset
        return UInt32(self[base])
            | UInt32(self[base + 1]) << 8
            | UInt32(self[base + 2]) << 16
            | UInt32(self[base + 3]) << 24
    }
}
