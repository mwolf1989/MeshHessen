import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Dfu/DfuPackage.cs

enum DfuPackageError: LocalizedError, Equatable {
    case unreadable(String)
    case missingManifest
    case invalidManifest(String)
    /// The package carries only SoftDevice/bootloader images (the found key), or nothing at all (nil).
    case noApplication(found: String?)
    case missingEntry(String)

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            String(localized: "The DFU package cannot be read: \(reason)")
        case .missingManifest:
            String(localized: "manifest.json not found in the DFU package.")
        case .invalidManifest(let reason):
            String(localized: "manifest.json is invalid: \(reason)")
        case .noApplication(let found?):
            String(localized: "The DFU package contains no application image (found “\(found)”). SoftDevice or bootloader packages must not be flashed as an application.")
        case .noApplication(nil):
            String(localized: "The DFU package contains no firmware image.")
        case .missingEntry(let name):
            String(localized: "“\(name)” is missing from the DFU package.")
        }
    }
}

/// Contents of a Nordic DFU `.zip` package: the init packet (`.dat`) and the application image (`.bin`).
struct DfuPackage: Sendable {
    /// Entries larger than this are ignored (an nRF52840 application is well below 1 MB).
    static let maximumEntrySize = 8 * 1024 * 1024

    let applicationBinary: Data
    let initPacket: Data
    let binFileName: String
    let datFileName: String
    /// Number of images the manifest declares; only the application is ever flashed.
    let imageCount: Int

    /// A secure-DFU init packet is a signed protobuf; legacy init packets are a few bytes.
    var hasSecureInitPacket: Bool { initPacket.count > 256 }

    init(zipURL: URL) throws {
        let archive: Data
        do {
            archive = try Data(contentsOf: zipURL, options: .mappedIfSafe)
        } catch {
            throw DfuPackageError.unreadable(error.localizedDescription)
        }
        try self.init(zipData: archive)
    }

    init(zipData: Data) throws {
        let entries: [String: Data]
        do {
            entries = try MapZIPArchive.readEntries(from: zipData, maximumEntrySize: Self.maximumEntrySize)
        } catch {
            throw DfuPackageError.unreadable(error.localizedDescription)
        }
        try self.init(entries: entries)
    }

    /// Resolves `manifest.json` → application entry → `.dat` / `.bin`. Refuses packages without an
    /// application image (SoftDevice/bootloader-only packages must never be flashed as an application).
    init(entries: [String: Data]) throws {
        guard let manifestData = entries["manifest.json"] else {
            throw DfuPackageError.missingManifest
        }
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: manifestData)
        } catch {
            throw DfuPackageError.invalidManifest(error.localizedDescription)
        }
        guard let manifest = (root as? [String: Any])?["manifest"] as? [String: Any] else {
            throw DfuPackageError.invalidManifest("no 'manifest' object")
        }

        let otherImages = ["softdevice_bootloader", "bootloader", "softdevice"]
        guard let application = manifest["application"] as? [String: Any] else {
            throw DfuPackageError.noApplication(found: otherImages.first { manifest[$0] != nil })
        }
        guard let bin = application["bin_file"] as? String, !bin.isEmpty,
              let dat = application["dat_file"] as? String, !dat.isEmpty else {
            throw DfuPackageError.invalidManifest("application entry lacks bin_file/dat_file")
        }
        guard let initPacket = entries[dat], !initPacket.isEmpty else { throw DfuPackageError.missingEntry(dat) }
        guard let firmware = entries[bin], !firmware.isEmpty else { throw DfuPackageError.missingEntry(bin) }

        self.applicationBinary = firmware
        self.initPacket = initPacket
        self.binFileName = bin
        self.datFileName = dat
        self.imageCount = (["application"] + otherImages).filter { manifest[$0] != nil }.count
        if imageCount > 1 {
            AppLogger.shared.log("[DFU] Package declares \(imageCount) images; only the application (\(bin)) is flashed")
        }
    }
}
