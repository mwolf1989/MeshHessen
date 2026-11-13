import CryptoKit
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/FirmwareRetriever.cs

enum FirmwareRetrieverError: LocalizedError, Equatable {
    /// No candidate artifact exists for this release and target.
    case artifactNotFound(String)
    /// A file was downloaded but failed the manifest size/MD5 check.
    case verificationFailed(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .artifactNotFound(let name):
            String(localized: "No firmware file found for \(name).")
        case .verificationFailed(let name):
            String(localized: "Downloaded firmware \(name) failed the integrity check.")
        case .network(let message):
            String(localized: "Firmware download failed: \(message)")
        }
    }
}

/// Resolves and downloads firmware artifacts from release.meshtastic.org into `<cache>/<version>/`.
/// Mirrors the Android/Windows lookup order so all clients flash the same bytes:
/// ESP32 OTA image: `.mt.json` → `app0` entry (MD5/size verified) → `-update.bin` → `.bin` → release zip.
/// nRF52 Bluetooth DFU: `-ota.zip`. USB: `.uf2`.
final class FirmwareRetriever: Sendable {
    /// One step of the download order.
    enum Candidate: Equatable, Sendable {
        /// The per-target `.mt.json` manifest; its `app0` entry names the image.
        case manifest(URL)
        /// A firmware file on release.meshtastic.org.
        case file(URL)
        /// Legacy all-in-one release zip (only old releases); the entry is picked by file name.
        case releaseZip(URL)

        var url: URL {
            switch self {
            case .manifest(let url), .file(let url), .releaseZip(let url): url
            }
        }
    }

    let cacheDirectory: URL
    private let httpClient: any FirmwareHTTPClient

    /// Entries of a legacy release zip are read into memory; firmware images are a few MB.
    private static let maximumZipEntrySize = 16 * 1024 * 1024

    init(
        httpClient: any FirmwareHTTPClient = URLSessionFirmwareHTTPClient(),
        cacheDirectory: URL = FirmwareCatalogService.defaultCacheDirectory
    ) {
        self.httpClient = httpClient
        self.cacheDirectory = cacheDirectory
    }

    convenience init(session: URLSession, cacheDirectory: URL = FirmwareCatalogService.defaultCacheDirectory) {
        self.init(httpClient: URLSessionFirmwareHTTPClient(session: session), cacheDirectory: cacheDirectory)
    }

    // MARK: - Naming (pure)

    static func artifactBaseURL(for release: FirmwareRelease) -> URL? {
        URL(string: "\(FirmwareCatalogService.releaseBaseURL)/\(release.version)")
    }

    static func fileName(target: String, version: String, suffix: String) -> String {
        "firmware-\(target)-\(version)\(suffix)"
    }

    /// Download order for one artifact kind, most authoritative first.
    static func artifactURLCandidates(
        release: FirmwareRelease,
        target: String,
        kind: FirmwareArtifactKind,
        architecture: String? = nil
    ) -> [Candidate] {
        guard let base = artifactBaseURL(for: release), !target.isEmpty else { return [] }
        let version = release.version
        func url(_ suffix: String) -> URL {
            base.appendingPathComponent(fileName(target: target, version: version, suffix: suffix))
        }

        var candidates: [Candidate]
        switch kind {
        case .espOtaBin:
            candidates = [.manifest(url(".mt.json")), .file(url("-update.bin")), .file(url(".bin"))]
        case .nrfOtaZip:
            candidates = [.file(url("-ota.zip"))]
        case .uf2:
            candidates = [.file(url(".uf2"))]
        }
        if release.zipURL.lowercased().hasSuffix(".zip") {
            let zip = architecture.map { resolveZipURL(release.zipURL, targetArchitecture: $0) } ?? release.zipURL
            if let zipURL = URL(string: zip) {
                candidates.append(.releaseZip(zipURL))
            }
        }
        return candidates
    }

    /// Cache file names for a kind, in the order `cachedArtifact` checks them.
    static func cachedFileNames(target: String, version: String, kind: FirmwareArtifactKind) -> [String] {
        switch kind {
        case .espOtaBin:
            [fileName(target: target, version: version, suffix: ".bin"),
             fileName(target: target, version: version, suffix: "-update.bin")]
        case .nrfOtaZip:
            [fileName(target: target, version: version, suffix: "-ota.zip")]
        case .uf2:
            [fileName(target: target, version: version, suffix: ".uf2")]
        }
    }

    private static let knownZipArchitectures = [
        "esp32-s3", "esp32-c3", "esp32-c6", "nrf52840", "rp2040", "stm32", "esp32",
    ]

    /// Old release zips were per architecture; swap the architecture in the URL for the device's one.
    static func resolveZipURL(_ url: String, targetArchitecture: String) -> String {
        for architecture in knownZipArchitectures {
            if let range = url.range(of: architecture, options: .caseInsensitive) {
                return url.replacingCharacters(in: range, with: targetArchitecture.lowercased())
            }
        }
        return url
    }

    // MARK: - Manifest (pure)

    /// The `app0` (main application) entry of a `.mt.json`, or nil.
    static func otaEntry(inManifest data: Data) -> FirmwareManifestFile? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let files = root["files"] as? [Any] else { return nil }
        for case let file as [String: Any] in files where file["part_name"] as? String == "app0" {
            guard let name = file["name"] as? String, !name.isEmpty else { return nil }
            return FirmwareManifestFile(
                name: name,
                partName: "app0",
                md5: file["md5"] as? String ?? "",
                bytes: (file["bytes"] as? NSNumber)?.intValue ?? 0
            )
        }
        return nil
    }

    /// The `mcu` field of a `.mt.json` (e.g. "esp32s3"), used to cross-check the image header.
    static func manifestMcu(_ data: Data) -> String? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["mcu"] as? String
    }

    /// Boards a release was built for, lower-cased. Newer releases publish `zip_url` as a JSON target
    /// manifest (`{"targets":[{"board":…}]}`); anything else yields nil ("unknown", not "unsupported").
    static func parseReleaseTargets(_ data: Data) -> Set<String>? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let targets = root["targets"] as? [Any] else { return nil }
        var boards = Set<String>()
        for case let target as [String: Any] in targets {
            if let board = target["board"] as? String {
                boards.insert(board.lowercased())
            }
        }
        return boards
    }

    /// True when `fileURL` matches the manifest entry's size and MD5 (or when there is no entry).
    static func matchesManifest(_ fileURL: URL, expected: FirmwareManifestFile?) -> Bool {
        guard let expected else { return true }
        guard let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else { return false }
        if expected.bytes > 0, data.count != expected.bytes { return false }
        guard !expected.md5.isEmpty else { return true }
        let digest = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digest.caseInsensitiveCompare(expected.md5) == .orderedSame
    }

    /// Size and SHA-256 of a local file.
    static func describe(_ fileURL: URL) throws -> FirmwareArtifact {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return FirmwareArtifact(url: fileURL, size: data.count, sha256: Data(SHA256.hash(data: data)))
    }

    // MARK: - Cache

    func releaseDirectory(for release: FirmwareRelease) -> URL {
        cacheDirectory.appendingPathComponent(release.version, isDirectory: true)
    }

    /// An already downloaded artifact for this release, device and kind, or nil. Lets the UI mark
    /// releases as usable offline before any download is attempted.
    func cachedArtifact(release: FirmwareRelease, hardware: DeviceHardware, kind: FirmwareArtifactKind) -> URL? {
        let directory = releaseDirectory(for: release)
        for name in Self.cachedFileNames(target: hardware.effectiveTarget, version: release.version, kind: kind) {
            let url = directory.appendingPathComponent(name)
            if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
               size.intValue > 0 {
                return url
            }
        }
        return nil
    }

    // MARK: - Download

    /// Downloads (or reuses from the cache) the artifact of `kind` for the device, verified against the
    /// manifest where one exists. Every file is written to `<name>.part` first and renamed only after the
    /// check passed; a failed check removes the `.part` file.
    func download(
        release: FirmwareRelease,
        hardware: DeviceHardware,
        kind: FirmwareArtifactKind,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> FirmwareArtifact {
        let target = hardware.effectiveTarget
        let candidates = Self.artifactURLCandidates(
            release: release,
            target: target,
            kind: kind,
            architecture: hardware.architecture.isEmpty ? nil : hardware.architecture
        )
        var failure: FirmwareRetrieverError?

        for candidate in candidates {
            try Task.checkCancellation()
            do {
                let result: FirmwareArtifact?
                switch candidate {
                case .manifest(let url):
                    result = try await downloadViaManifest(url, release: release, progress: progress)
                case .file(let url):
                    result = try await downloadFile(url, release: release, expected: nil, progress: progress)
                case .releaseZip(let url):
                    result = try await extractFromReleaseZip(
                        url,
                        release: release,
                        target: target,
                        kind: kind,
                        progress: progress
                    )
                }
                if let result { return result }
            } catch let error as FirmwareRetrieverError {
                AppLogger.shared.log("[FW] \(candidate.url.lastPathComponent): \(error.localizedDescription)")
                // The manifest is authoritative: an image that fails its check must not be fetched
                // again unverified under a fallback name (Windows falls back here; we refuse).
                if case .verificationFailed = error { throw error }
                failure = error
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                AppLogger.shared.log("[FW] \(candidate.url.lastPathComponent) failed: \(error.localizedDescription)")
                if failure == nil { failure = .network(error.localizedDescription) }
            }
        }
        throw failure ?? .artifactNotFound(Self.fileName(target: target, version: release.version, suffix: kind.fileSuffix))
    }

    /// Boards the release was built for (lower-cased), or nil when unknown.
    func releaseTargets(for release: FirmwareRelease) async -> Set<String>? {
        guard release.zipURL.lowercased().hasSuffix(".json"), let url = URL(string: release.zipURL) else {
            return nil
        }
        guard let response = try? await httpClient.get(FirmwareCatalogService.request(for: url)),
              response.isSuccess else { return nil }
        return Self.parseReleaseTargets(response.data)
    }

    // MARK: - Private

    private func downloadViaManifest(
        _ manifestURL: URL,
        release: FirmwareRelease,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> FirmwareArtifact? {
        let response = try await httpClient.get(FirmwareCatalogService.request(for: manifestURL))
        guard response.isSuccess else { return nil }
        guard let entry = Self.otaEntry(inManifest: response.data),
              !entry.name.contains("/"), !entry.name.contains("\\") else {
            AppLogger.shared.log("[FW] Manifest has no usable app0 entry — falling back to file names")
            return nil
        }
        let fileURL = manifestURL.deletingLastPathComponent().appendingPathComponent(entry.name)
        return try await downloadFile(fileURL, release: release, expected: entry, progress: progress)
    }

    /// Returns nil when the server has no such file (non-2xx); throws on network or verification errors.
    private func downloadFile(
        _ url: URL,
        release: FirmwareRelease,
        expected: FirmwareManifestFile?,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> FirmwareArtifact? {
        let fileManager = FileManager.default
        let directory = releaseDirectory(for: release)
        let fileName = url.lastPathComponent
        let destination = directory.appendingPathComponent(fileName)

        if let size = (try? fileManager.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber,
           size.intValue > 0,
           Self.matchesManifest(destination, expected: expected) {
            AppLogger.shared.log("[FW] Using cached \(fileName)")
            progress?(1)
            return try Self.describe(destination)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let partial = directory.appendingPathComponent(fileName + ".part")
        do {
            let status = try await httpClient.download(
                FirmwareCatalogService.request(for: url),
                to: partial,
                progress: progress
            )
            guard (200..<300).contains(status) else {
                try? fileManager.removeItem(at: partial)
                AppLogger.shared.log("[FW] \(fileName): HTTP \(status)")
                return nil
            }
            guard Self.matchesManifest(partial, expected: expected) else {
                try? fileManager.removeItem(at: partial)
                throw FirmwareRetrieverError.verificationFailed(fileName)
            }
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: partial, to: destination)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
        progress?(1)
        let artifact = try Self.describe(destination)
        AppLogger.shared.log("[FW] Downloaded \(fileName) (\(artifact.size) bytes)")
        return artifact
    }

    private func extractFromReleaseZip(
        _ zipURL: URL,
        release: FirmwareRelease,
        target: String,
        kind: FirmwareArtifactKind,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> FirmwareArtifact? {
        let fileManager = FileManager.default
        let directory = releaseDirectory(for: release)
        let zipPath = directory.appendingPathComponent(zipURL.lastPathComponent)

        if !fileManager.fileExists(atPath: zipPath.path) {
            guard try await downloadFile(zipURL, release: release, expected: nil, progress: progress) != nil else {
                return nil
            }
        }
        let archive = try Data(contentsOf: zipPath, options: .mappedIfSafe)
        let entries = try MapZIPArchive.readEntries(
            from: archive,
            maximumEntrySize: Self.maximumZipEntrySize
        ) { path in
            FirmwareFileInspector.isValidFirmwareFileName(path, target: target, fileExtension: kind.fileSuffix)
        }
        guard let (path, data) = entries.sorted(by: { $0.key < $1.key }).first else { return nil }
        let output = directory.appendingPathComponent((path as NSString).lastPathComponent)
        try data.write(to: output, options: .atomic)
        progress?(1)
        return try Self.describe(output)
    }
}
