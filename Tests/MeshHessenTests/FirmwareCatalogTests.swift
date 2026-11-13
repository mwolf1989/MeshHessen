import Foundation
import Testing

@testable import MeshHessen

/// In-memory HTTP stub for the firmware services (also used by `FirmwareRetrieverTests`):
/// no network access in tests.
actor StubFirmwareHTTPClient: FirmwareHTTPClient {
    struct Response: Sendable {
        let status: Int
        let body: Data
    }

    private let responses: [String: Response]
    private let error: URLError?
    private(set) var requests: [URLRequest] = []

    init(responses: [String: Response], error: URLError? = nil) {
        self.responses = responses
        self.error = error
    }

    var requestedURLs: [String] { requests.compactMap { $0.url?.absoluteString } }

    func get(_ request: URLRequest) async throws -> FirmwareHTTPResponse {
        let response = try respond(to: request)
        return FirmwareHTTPResponse(data: response.body, statusCode: response.status)
    }

    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> Int {
        let response = try respond(to: request)
        guard (200..<300).contains(response.status) else { return response.status }
        try response.body.write(to: destination)
        progress?(1)
        return response.status
    }

    private func respond(to request: URLRequest) throws -> Response {
        requests.append(request)
        if let error { throw error }
        return responses[request.url?.absoluteString ?? ""] ?? Response(status: 404, body: Data())
    }
}

/// Windows reference: MeshhessenClient.Tests/FirmwareUpdateTests.cs (catalog part).
@Suite("Firmware catalog")
struct FirmwareCatalogTests {
    static let hardwareJSON = """
        [
          {"hwModel":43,"hwModelSlug":"HELTEC_V3","platformioTarget":"heltec-v3","architecture":"esp32-s3","activelySupported":true,"displayName":"Heltec V3","supportLevel":1},
          {"hwModel":9,"hwModelSlug":"RAK4631","platformioTarget":"rak4631","architecture":"nrf52840","activelySupported":true,"displayName":"RAK WisBlock 4631","requiresDfu":true},
          {"hwModel":9,"hwModelSlug":"RAK4631","platformioTarget":"rak4631_eink","architecture":"nrf52840","activelySupported":true,"displayName":"RAK WisBlock 4631 (E-Ink)"},
          {"hwModel":1,"hwModelSlug":"TLORA_V2","platformioTarget":"tlora-v2","architecture":"esp32","activelySupported":false,"displayName":"LILYGO T-LoRa V2"}
        ]
        """

    static let releasesJSON = """
        {"releases":{
          "stable":[{"id":"v2.7.26.54e0d8d","title":"Meshtastic Firmware 2.7.26.54e0d8d Beta","page_url":"https://github.com/meshtastic/firmware/releases/tag/v2.7.26.54e0d8d","zip_url":"https://github.com/meshtastic/firmware/releases/download/v2.7.26.54e0d8d/firmware-2.7.26.54e0d8d.json","release_notes":"notes"}],
          "alpha":[{"id":"v2.8.2.d5f1619","title":"Meshtastic Firmware 2.8.2.d5f1619 Alpha","page_url":"","zip_url":"","release_notes":""}, {"title":"no id"}]
        },"pullRequests":[{"id":"pr"}]}
        """

    private static let apiHardwareURL = "https://api.meshtastic.org/resource/deviceHardware"
    private static let apiReleasesURL = "https://api.meshtastic.org/github/firmware/list"

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirmwareCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Parsing

    @Test("Hardware and release documents parse")
    func parsesHardwareAndReleases() throws {
        let hardware = FirmwareCatalogService.parseHardware(Data(Self.hardwareJSON.utf8))
        #expect(hardware.count == 4)
        #expect(hardware[0].isEsp32)
        #expect(hardware[0].firmwareArchitecture == .esp32s3)
        #expect(hardware[0].supportLevel == 1)
        #expect(hardware[0].requiresBootloaderUpgradeForOta == nil)
        #expect(hardware[1].isNrf52)
        #expect(hardware[1].requiresDfu == true)
        #expect(hardware[3].activelySupported == false)
        #expect(hardware[3].firmwareArchitecture == .esp32)

        let releases = FirmwareCatalogService.parseReleases(Data(Self.releasesJSON.utf8))
        #expect(releases.count == 2)
        #expect(releases[0].channel == .stable)
        #expect(releases[0].version == "2.7.26.54e0d8d")
        #expect(releases[0].numericVersion == FirmwareVersion(major: 2, minor: 7, patch: 26))
        #expect(releases[0].pageURL.hasSuffix("v2.7.26.54e0d8d"))
        #expect(releases[1].channel == .alpha)

        #expect(FirmwareCatalogService.parseHardware(Data("{}".utf8)).isEmpty)
        #expect(FirmwareCatalogService.parseReleases(Data("not json".utf8)).isEmpty)
    }

    // MARK: - Resolution

    @Test("Hardware resolution disambiguates by pio_env and falls back")
    func resolveHardware() throws {
        let hardware = FirmwareCatalogService.parseHardware(Data(Self.hardwareJSON.utf8))

        let plain = try #require(FirmwareCatalogService.resolveHardware(hwModel: 9, pioEnv: nil, in: hardware))
        #expect(plain.platformioTarget == "rak4631")

        let eink = try #require(FirmwareCatalogService.resolveHardware(hwModel: 9, pioEnv: "rak4631_eink", in: hardware))
        #expect(eink.platformioTarget == "rak4631_eink")
        #expect(eink.displayName.contains("E-Ink"))

        // Case-insensitive match keeps the catalog row but adopts the reported spelling.
        let caseInsensitive = try #require(
            FirmwareCatalogService.resolveHardware(hwModel: 9, pioEnv: "RAK4631_EINK", in: hardware)
        )
        #expect(caseInsensitive.platformioTarget == "RAK4631_EINK")
        #expect(caseInsensitive.displayName.contains("E-Ink"))

        // Unknown variant: first row of the model, target overridden by what the device reports.
        let variant = try #require(
            FirmwareCatalogService.resolveHardware(hwModel: 9, pioEnv: "rak4631_nomadstar", in: hardware)
        )
        #expect(variant.platformioTarget == "rak4631_nomadstar")
        #expect(variant.effectiveTarget == "rak4631_nomadstar")
        #expect(variant.displayName == "RAK WisBlock 4631")

        // Unknown hwModel but known target → target-only lookup.
        #expect(FirmwareCatalogService.resolveHardware(hwModel: 999, pioEnv: "heltec-v3", in: hardware)?.platformioTarget == "heltec-v3")
        #expect(FirmwareCatalogService.resolveHardware(hwModel: 999, pioEnv: "nope", in: hardware) == nil)
        #expect(FirmwareCatalogService.resolveHardware(hwModel: 999, pioEnv: "  ", in: hardware) == nil)
    }

    @Test(
        "Architecture guess covers common models in proto and Swift spelling",
        arguments: [
            ("HELTEC_V3", "esp32"),
            ("heltecV3", "esp32"),
            ("TBEAM", "esp32"),
            ("RAK4631", "nrf52840"),
            ("rak4631", "nrf52840"),
            ("T_ECHO", "nrf52840"),
            ("tEcho", "nrf52840"),
            ("HELTEC_MESH_NODE_T114", "nrf52840"),
            ("heltecMeshNodeT114", "nrf52840"),
            ("RPI_PICO", "rp2040"),
            ("", nil),
            ("SOMETHING_ELSE", nil),
        ] as [(String, String?)]
    )
    func guessArchitecture(name: String, expected: String?) {
        #expect(FirmwareCatalogService.guessArchitecture(hwModelName: name) == expected)
    }

    @Test("Catalog architecture strings map to firmware architectures")
    func architectureMapping() {
        #expect(FirmwareArchitecture(catalogValue: "esp32s3") == .esp32s3)
        #expect(FirmwareArchitecture(catalogValue: "ESP32-C3") == .esp32c3)
        #expect(FirmwareArchitecture(catalogValue: "nrf52840") == .nrf52840)
        #expect(FirmwareArchitecture(catalogValue: "rp2040") == .rp2040)
        #expect(FirmwareArchitecture(catalogValue: "rp2350") == .rp2350)
        #expect(FirmwareArchitecture(catalogValue: "stm32") == .unknown)
        #expect(FirmwareArchitecture.esp32s3.espChipId == 9)
        #expect(FirmwareArchitecture.nrf52840.supportedArtifactKinds == [.nrfOtaZip, .uf2])
        #expect(FirmwareUpdateMethod.wifiOta.artifactKind == .espOtaBin)
        #expect(FirmwareUpdateMethod.bleDfu.artifactKind == .nrfOtaZip)
    }

    // MARK: - Load / cache

    @Test("Online load parses, writes the cache and sends the wizard User-Agent")
    func onlineLoadWritesCache() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = StubFirmwareHTTPClient(responses: [
            Self.apiHardwareURL: .init(status: 200, body: Data(Self.hardwareJSON.utf8)),
            Self.apiReleasesURL: .init(status: 200, body: Data(Self.releasesJSON.utf8)),
        ])
        let service = FirmwareCatalogService(httpClient: client, cacheDirectory: cache)

        let catalog = await service.load(forceRefresh: true)

        #expect(catalog.isFromCache == false)
        #expect(catalog.hardware.count == 4)
        #expect(catalog.stable.count == 1)
        #expect(catalog.alpha.count == 1)
        #expect(catalog.errorMessage == nil)
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("deviceHardware.json").path))
        #expect(FileManager.default.fileExists(atPath: cache.appendingPathComponent("releases.json").path))
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "MeshHessen-FirmwareWizard/1.0" })
        #expect(requests.allSatisfy { $0.timeoutInterval == 25 })
    }

    @Test("Offline load falls back to the cache with its date and the online error")
    func offlineFallbackUsesCache() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data(Self.hardwareJSON.utf8).write(to: cache.appendingPathComponent("deviceHardware.json"))
        try Data(Self.releasesJSON.utf8).write(to: cache.appendingPathComponent("releases.json"))

        let client = StubFirmwareHTTPClient(responses: [:], error: URLError(.notConnectedToInternet))
        let service = FirmwareCatalogService(httpClient: client, cacheDirectory: cache)
        let catalog = await service.load(forceRefresh: true)

        #expect(catalog.isFromCache)
        #expect(catalog.cacheDate != nil)
        #expect(catalog.hardware.count == 4)
        #expect(catalog.releases.count == 2)
        #expect(catalog.errorMessage != nil)
    }

    @Test("A fresh cache is used without network unless refresh is forced")
    func freshCacheSkipsNetwork() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        try Data(Self.hardwareJSON.utf8).write(to: cache.appendingPathComponent("deviceHardware.json"))
        try Data(Self.releasesJSON.utf8).write(to: cache.appendingPathComponent("releases.json"))

        let client = StubFirmwareHTTPClient(responses: [:], error: URLError(.notConnectedToInternet))
        let service = FirmwareCatalogService(httpClient: client, cacheDirectory: cache, cacheMaxAge: 3600)
        let catalog = await service.load()

        #expect(catalog.isFromCache)
        #expect(catalog.errorMessage == nil)
        #expect(await client.requests.isEmpty)
    }

    @Test("No network and no cache yields an empty catalog with an error")
    func emptyWithoutAnySource() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = StubFirmwareHTTPClient(responses: [
            Self.apiHardwareURL: .init(status: 503, body: Data()),
            Self.apiReleasesURL: .init(status: 503, body: Data()),
        ])
        let service = FirmwareCatalogService(httpClient: client, cacheDirectory: cache)
        let catalog = await service.load(forceRefresh: true)

        #expect(catalog.isEmpty)
        #expect(catalog.errorMessage != nil)
        #expect(!FileManager.default.fileExists(atPath: cache.appendingPathComponent("deviceHardware.json").path))
    }
}
