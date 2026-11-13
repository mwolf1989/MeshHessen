import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/FirmwareCatalogService.cs

// MARK: - HTTP

struct FirmwareHTTPResponse: Sendable {
    let data: Data
    let statusCode: Int

    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Network seam of the firmware services; tests inject a stub (see `UpdateHTTPClient` for the pattern).
protocol FirmwareHTTPClient: Sendable {
    /// Fetches a small document into memory.
    func get(_ request: URLRequest) async throws -> FirmwareHTTPResponse

    /// Streams the response body into `destination` (created or replaced) when the status is 2xx and
    /// returns the HTTP status. On a non-2xx status nothing is written. `progress` gets 0…1 when the
    /// length is known.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int
}

/// Production client on top of an injectable `URLSession`.
struct URLSessionFirmwareHTTPClient: FirmwareHTTPClient {
    let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func get(_ request: URLRequest) async throws -> FirmwareHTTPResponse {
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return FirmwareHTTPResponse(data: data, statusCode: status)
    }

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int {
        let (bytes, response) = try await session.bytes(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { return status }

        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }

        let expected = response.expectedContentLength
        let chunkSize = 64 * 1024
        var buffer = Data()
        buffer.reserveCapacity(chunkSize)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= chunkSize {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { progress?(min(1, Double(written) / Double(expected))) }
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        return status
    }
}

// MARK: - Catalog

/// Result of loading the hardware catalog and the release list, from the network or the local cache.
struct FirmwareCatalog: Sendable {
    let hardware: [DeviceHardware]
    let releases: [FirmwareRelease]
    let isFromCache: Bool
    /// When the data was fetched (now for an online load, the cache file's date otherwise).
    let cacheDate: Date?
    /// Why the online load failed (also set when the cache filled in), or why nothing is available.
    let errorMessage: String?

    var isEmpty: Bool { hardware.isEmpty && releases.isEmpty }
    var stable: [FirmwareRelease] { releases.filter { $0.channel == .stable } }
    var alpha: [FirmwareRelease] { releases.filter { $0.channel == .alpha } }

    static func empty(errorMessage: String?) -> FirmwareCatalog {
        FirmwareCatalog(hardware: [], releases: [], isFromCache: true, cacheDate: nil, errorMessage: errorMessage)
    }
}

enum FirmwareCatalogError: LocalizedError {
    case httpStatus(Int)
    case emptyDocument

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status): "HTTP \(status)"
        case .emptyDocument: "API returned an empty document"
        }
    }
}

/// Fetches the Meshtastic public API documents the firmware update needs (device-hardware catalog and the
/// stable/alpha release list) and mirrors them into the cache directory so it keeps working offline.
final class FirmwareCatalogService: Sendable {
    static let apiBaseURL = "https://api.meshtastic.org/"
    static let releaseBaseURL = "https://release.meshtastic.org"
    static let webFlasherURL = "https://flasher.meshtastic.org"
    /// No personal data in the User-Agent.
    static let userAgent = "MeshHessen-FirmwareWizard/1.0"
    static let requestTimeout: TimeInterval = 25

    static let hardwareFileName = "deviceHardware.json"
    static let releasesFileName = "releases.json"

    /// `~/Library/Application Support/MeshHessen/firmware/` (inside the sandbox container).
    static var defaultCacheDirectory: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("firmware", isDirectory: true)
    }

    let cacheDirectory: URL
    /// A cache younger than this is used without going online unless `forceRefresh` is set.
    let cacheMaxAge: TimeInterval
    private let httpClient: any FirmwareHTTPClient

    init(
        httpClient: any FirmwareHTTPClient = URLSessionFirmwareHTTPClient(),
        cacheDirectory: URL = FirmwareCatalogService.defaultCacheDirectory,
        cacheMaxAge: TimeInterval = 3600
    ) {
        self.httpClient = httpClient
        self.cacheDirectory = cacheDirectory
        self.cacheMaxAge = cacheMaxAge
    }

    convenience init(session: URLSession, cacheDirectory: URL = FirmwareCatalogService.defaultCacheDirectory) {
        self.init(httpClient: URLSessionFirmwareHTTPClient(session: session), cacheDirectory: cacheDirectory)
    }

    static func request(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    // MARK: - Load

    /// Never throws. Without `forceRefresh` a fresh cache (younger than `cacheMaxAge`) is returned directly;
    /// otherwise the API is asked first and the cache is the fallback. An empty catalog with
    /// `errorMessage` set means neither source was available.
    func load(forceRefresh: Bool = false) async -> FirmwareCatalog {
        if !forceRefresh, let date = cacheFileDate(), Date().timeIntervalSince(date) < cacheMaxAge {
            let cached = loadFromCache()
            if !cached.hardware.isEmpty, !cached.releases.isEmpty {
                return cached
            }
        }

        let onlineError: String
        do {
            return try await loadOnline()
        } catch is CancellationError {
            onlineError = "Cancelled"
        } catch {
            onlineError = error.localizedDescription
            AppLogger.shared.log("[FW] Catalog online fetch failed: \(error.localizedDescription) — trying cache")
        }
        return loadFromCache(onlineError: onlineError)
    }

    /// Cache only (no network).
    func loadFromCache(onlineError: String? = nil) -> FirmwareCatalog {
        let fileManager = FileManager.default
        let hardwareURL = cacheDirectory.appendingPathComponent(Self.hardwareFileName)
        let releasesURL = cacheDirectory.appendingPathComponent(Self.releasesFileName)
        let hasHardware = fileManager.fileExists(atPath: hardwareURL.path)
        let hasReleases = fileManager.fileExists(atPath: releasesURL.path)
        guard hasHardware || hasReleases else {
            return .empty(errorMessage: onlineError ?? "No cached firmware catalog")
        }

        do {
            let hardware = hasHardware ? Self.parseHardware(try Data(contentsOf: hardwareURL)) : []
            let releases = hasReleases ? Self.parseReleases(try Data(contentsOf: releasesURL)) : []
            let date = cacheFileDate()
            AppLogger.shared.log("[FW] Catalog from cache: \(hardware.count) devices, \(releases.count) releases")
            return FirmwareCatalog(
                hardware: hardware,
                releases: releases,
                isFromCache: true,
                cacheDate: date,
                errorMessage: onlineError
            )
        } catch {
            AppLogger.shared.log("[FW] Catalog cache read failed: \(error.localizedDescription)")
            return .empty(errorMessage: onlineError ?? error.localizedDescription)
        }
    }

    private func loadOnline() async throws -> FirmwareCatalog {
        guard let hardwareURL = URL(string: Self.apiBaseURL + "resource/deviceHardware"),
              let releasesURL = URL(string: Self.apiBaseURL + "github/firmware/list") else {
            throw URLError(.badURL)
        }
        async let hardwareResponse = httpClient.get(Self.request(for: hardwareURL))
        async let releasesResponse = httpClient.get(Self.request(for: releasesURL))
        let (hardwareDocument, releasesDocument) = try await (hardwareResponse, releasesResponse)

        for response in [hardwareDocument, releasesDocument] where !response.isSuccess {
            throw FirmwareCatalogError.httpStatus(response.statusCode)
        }
        let hardware = Self.parseHardware(hardwareDocument.data)
        let releases = Self.parseReleases(releasesDocument.data)
        guard !hardware.isEmpty, !releases.isEmpty else {
            throw FirmwareCatalogError.emptyDocument
        }

        do {
            try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
            try hardwareDocument.data.write(
                to: cacheDirectory.appendingPathComponent(Self.hardwareFileName),
                options: .atomic
            )
            try releasesDocument.data.write(
                to: cacheDirectory.appendingPathComponent(Self.releasesFileName),
                options: .atomic
            )
        } catch {
            AppLogger.shared.log("[FW] Catalog cache write failed: \(error.localizedDescription)")
        }

        AppLogger.shared.log("[FW] Catalog online: \(hardware.count) devices, \(releases.count) releases")
        return FirmwareCatalog(
            hardware: hardware,
            releases: releases,
            isFromCache: false,
            cacheDate: Date(),
            errorMessage: nil
        )
    }

    /// Modification date of the hardware cache file (or the release file when only that exists).
    private func cacheFileDate() -> Date? {
        for name in [Self.hardwareFileName, Self.releasesFileName] {
            let url = cacheDirectory.appendingPathComponent(name)
            if let date = try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date {
                return date
            }
        }
        return nil
    }

    // MARK: - Parsing (pure)

    static func parseHardware(_ data: Data) -> [DeviceHardware] {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return [] }
        return array.compactMap { element -> DeviceHardware? in
            guard let entry = element as? [String: Any] else { return nil }
            return DeviceHardware(
                hwModel: int(entry["hwModel"]) ?? 0,
                hwModelSlug: entry["hwModelSlug"] as? String ?? "",
                platformioTarget: entry["platformioTarget"] as? String ?? "",
                architecture: entry["architecture"] as? String ?? "",
                activelySupported: bool(entry["activelySupported"]) ?? false,
                displayName: entry["displayName"] as? String ?? "",
                requiresDfu: bool(entry["requiresDfu"]),
                requiresBootloaderUpgradeForOta: bool(entry["requiresBootloaderUpgradeForOta"]),
                supportLevel: int(entry["supportLevel"])
            )
        }
    }

    static func parseReleases(_ data: Data) -> [FirmwareRelease] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let releases = root["releases"] as? [String: Any] else {
            return []
        }
        var result: [FirmwareRelease] = []
        for (key, channel) in [("stable", FirmwareChannel.stable), ("alpha", FirmwareChannel.alpha)] {
            guard let entries = releases[key] as? [Any] else { continue }
            for case let entry as [String: Any] in entries {
                guard let id = entry["id"] as? String,
                      !id.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                result.append(
                    FirmwareRelease(
                        id: id,
                        title: entry["title"] as? String ?? id,
                        pageURL: entry["page_url"] as? String ?? "",
                        zipURL: entry["zip_url"] as? String ?? "",
                        releaseNotes: entry["release_notes"] as? String ?? "",
                        channel: channel
                    )
                )
            }
        }
        return result
    }

    // MARK: - Hardware resolution (pure)

    /// Picks the catalog entry for a device: all entries with its hardware-model number, disambiguated by the
    /// PlatformIO environment the device reports (exact, then case-insensitive, then the first entry). When
    /// the hwModel is unknown the pioEnv alone is tried. The reported pioEnv wins over the catalog target
    /// because it names the build actually running on the board (e.g. a RAK4631 variant).
    static func resolveHardware(hwModel: Int, pioEnv: String?, in catalog: [DeviceHardware]) -> DeviceHardware? {
        let trimmed = pioEnv?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let target: String? = trimmed.isEmpty ? nil : trimmed

        var candidates = catalog.filter { $0.hwModel == hwModel }
        if candidates.isEmpty, let target {
            candidates = catalog.filter { $0.platformioTarget.caseInsensitiveCompare(target) == .orderedSame }
        }
        guard var match = candidates.first else { return nil }

        if let target {
            match = candidates.first { $0.platformioTarget == target }
                ?? candidates.first { $0.platformioTarget.caseInsensitiveCompare(target) == .orderedSame }
                ?? match
            if match.platformioTarget != target {
                match.platformioTarget = target
            }
        }
        return match
    }

    /// Best-effort architecture from a hardware-model name, for devices missing from the catalog (or when
    /// the catalog is unavailable). Accepts proto names ("HELTEC_V3") and Swift case names ("heltecV3").
    /// Returns "esp32", "nrf52840", "rp2040" or nil.
    static func guessArchitecture(hwModelName: String) -> String? {
        let name = normalizedModelName(hwModelName)
        guard !name.isEmpty else { return nil }
        if nrfKeywords.contains(where: { name.contains($0) }) { return "nrf52840" }
        if rpKeywords.contains(where: { name.contains($0) }) { return "rp2040" }
        if espKeywords.contains(where: { name.contains($0) }) { return "esp32" }
        return nil
    }

    // MARK: - Private

    private static let nrfKeywords = [
        "RAK4631", "RAK2560", "RAK3", "T_ECHO", "TECHO", "T114", "NANO_G2", "WIO_WM1110", "WIO_TRACKER",
        "TRACKER_T1000", "CANARYONE", "NRF52", "PPR", "XIAO_NRF52", "MESHLINK", "THINKNODE_M1", "T1000",
        "ME25LS01", "MS24SF1", "SEEED_SOLAR", "HELTEC_MESH_NODE", "T_IMPULSE", "MUZI", "R1_NEO", "FEATHER_DIY",
        "RAK_WISMESH",
    ].map(normalizedModelName)

    private static let rpKeywords = [
        "RPI_PICO", "PICO", "RP2040", "RP2350", "SENSELORA_RP2040", "RAK11310", "XIAO_RP2040",
    ].map(normalizedModelName)

    private static let espKeywords = [
        "TLORA", "TBEAM", "HELTEC", "T_DECK", "TDECK", "T_WATCH", "TWATCH", "STATION_G1", "STATION_G2", "DIY_V1",
        "NANO_G1", "M5STACK", "ESP32", "PICOMPUTER", "T_ETH", "TRACKER_T1000_E_ESP", "UNPHONE", "CHATTER",
        "WIPHONE", "SENSECAP", "SEEED_XIAO_S3", "RAK11200", "T_LORA_PAGER", "TLORA_PAGER", "RADIOMASTER",
        "MESH_TAB", "THINKNODE_M2", "T_ETH_ELITE", "CDEBYTE", "BETAFPV", "LILYGO",
    ].map(normalizedModelName)

    /// Upper case without underscores, so "HELTEC_MESH_NODE_T114" and "heltecMeshNodeT114" compare equal.
    private static func normalizedModelName(_ name: String) -> String {
        name.uppercased().replacingOccurrences(of: "_", with: "")
    }

    private static func int(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBool(number) else { return nil }
        let double = number.doubleValue
        guard double == double.rounded(), abs(double) <= Double(Int32.max) else { return nil }
        return number.intValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBool(number) else { return nil }
        return number.boolValue
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
