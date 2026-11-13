import AppKit
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/Uf2UsbFlasher.cs

/// What a UF2 bootloader says about itself in `INFO_UF2.TXT`.
struct Uf2BootloaderInfo: Equatable, Sendable {
    var bootloaderVersion: String?
    var model: String?
    var boardId: String?
    var softDevice: String?

    var summary: String {
        "Board-ID \(boardId ?? "?") · Bootloader \(bootloaderVersion ?? "?")"
            + (softDevice.map { " · \($0)" } ?? "")
    }
}

enum Uf2FlashError: LocalizedError, Equatable {
    case noDrive
    case accessDenied
    case notBootloaderDrive(String)
    case copyFailed(String)
    case notConsumed(String)

    var errorDescription: String? {
        switch self {
        case .noDrive:
            String(localized: "No UF2 boot drive appeared. Double-press the device's reset button to start the bootloader manually and try again.")
        case .accessDenied:
            String(localized: "Access to the boot drive was not granted.")
        case .notBootloaderDrive(let name):
            String(localized: "“\(name)” is not a UF2 boot drive (INFO_UF2.TXT is missing).")
        case .copyFailed(let reason):
            String(localized: "Copying the firmware to the boot drive failed: \(reason)")
        case .notConsumed(let name):
            String(localized: "The boot drive “\(name)” is still mounted after the copy — the device did not take the firmware.")
        }
    }
}

/// UF2 mass-storage flashing (nRF52 / RP2040): the bootloader shows up as a removable drive carrying
/// `INFO_UF2.TXT`, consumes a `.uf2` copied onto its root and reboots — the drive vanishing is success.
enum Uf2VolumeFlasher {
    static let infoFileName = "INFO_UF2.TXT"
    static let connectedWaitTimeout: Duration = .seconds(90)
    static let recoveryWaitTimeout: Duration = .seconds(120)
    static let detachTimeout: Duration = .seconds(60)
    static let dfuSettleDelay: Duration = .milliseconds(800)
    static let accessPrompt = String(localized: "Select the boot drive of the device to allow copying the firmware")

    /// Parses `INFO_UF2.TXT` ("UF2 Bootloader 0.9.2 …", "Model: …", "Board-ID: RAK4631", "SoftDevice: S140 …").
    static func parseInfoUf2(_ text: String) -> Uf2BootloaderInfo {
        var info = Uf2BootloaderInfo()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if let value = value(of: "Board-ID:", in: line) {
                info.boardId = value
            } else if let value = value(of: "SoftDevice:", in: line) {
                info.softDevice = value
            } else if let value = value(of: "Model:", in: line) {
                info.model = value
            } else if line.range(of: "UF2 Bootloader", options: [.caseInsensitive, .anchored]) != nil,
                      let match = line.firstMatch(of: #/(?i)UF2 Bootloader\s+v?(\S+)/#) {
                info.bootloaderVersion = String(match.1)
            }
        }
        return info
    }

    /// `INFO_UF2.TXT` of a volume, or nil when it is missing or unreadable (e.g. not yet granted).
    static func readInfo(atVolume volume: URL) -> Uf2BootloaderInfo? {
        let file = volume.appendingPathComponent(infoFileName)
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return parseInfoUf2(text)
    }

    /// Mounted removable / ejectable volumes (candidates for a boot drive).
    static func removableVolumes() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsRemovable == true || values.volumeIsEjectable == true
                || values.volumeIsInternal == false
        }
    }

    /// Copies `source` onto the root of `volume` in 64 KiB blocks. An I/O error after the last byte counts
    /// as success: the bootloader often reboots while the file is being closed. Runs off the main actor.
    static func copy(
        _ source: URL,
        toVolume volume: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let destination = volume.appendingPathComponent(source.lastPathComponent)
        try await Task.detached(priority: .userInitiated) {
            try copySync(source, to: destination, progress: progress)
        }.value
    }

    /// Synchronous copy (see `copy`). Internal for tests.
    static func copySync(_ source: URL, to destination: URL, progress: (Double) -> Void) throws {
        let data: Data
        do {
            data = try Data(contentsOf: source, options: .mappedIfSafe)
        } catch {
            throw Uf2FlashError.copyFailed(error.localizedDescription)
        }
        let total = data.count
        var written = 0
        do {
            guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
                throw Uf2FlashError.copyFailed(String(localized: "cannot create \(destination.lastPathComponent)"))
            }
            let handle = try FileHandle(forWritingTo: destination)
            defer { try? handle.close() }
            let block = 64 * 1024
            while written < total {
                let end = min(written + block, total)
                try handle.write(contentsOf: data.subdata(in: written..<end))
                written = end
                progress(Double(written) / Double(max(total, 1)))
            }
            try handle.synchronize()
        } catch let error as Uf2FlashError {
            throw error
        } catch {
            guard written >= total else {
                AppLogger.shared.log("[UF2] Copy failed at \(written)/\(total): \(error.localizedDescription)")
                throw Uf2FlashError.copyFailed(error.localizedDescription)
            }
            AppLogger.shared.log("[UF2] I/O error after the last block (\(error.localizedDescription)) — treating as consumed")
        }
        AppLogger.shared.log("[UF2] Copied \(written) bytes to \(destination.path)")
    }

    // MARK: - Private

    private static func value(of prefix: String, in line: String) -> String? {
        guard line.range(of: prefix, options: [.caseInsensitive, .anchored]) != nil else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }
}

/// Watches `NSWorkspace` mount / unmount notifications while the assistant waits for a boot drive.
@MainActor
final class Uf2VolumeMonitor {
    private(set) var mountedSinceStart: [URL] = []
    private(set) var unmountedSinceStart: [URL] = []
    private var observers: [NSObjectProtocol] = []

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) {
        observers.append(center.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let url { self?.mountedSinceStart.append(url) } }
        })
        observers.append(center.addObserver(
            forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
        ) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { if let url { self?.unmountedSinceStart.append(url) } }
        })
    }

    func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    /// Volumes mounted since the monitor started that are still mounted.
    var newVolumes: [URL] {
        mountedSinceStart.filter { url in !unmountedSinceStart.contains { Self.same($0, url) } }
    }

    func hasUnmounted(_ volume: URL) -> Bool {
        if unmountedSinceStart.contains(where: { Self.same($0, volume) }) { return true }
        return !FileManager.default.fileExists(atPath: volume.path)
    }

    nonisolated static func same(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            == rhs.standardizedFileURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
