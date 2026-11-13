import CryptoKit
import Foundation
import Testing

@testable import MeshHessen

/// Windows reference: MeshhessenClient.Tests/FirmwareUpdateTests.cs (retriever part).
@Suite("Firmware retriever")
struct FirmwareRetrieverTests {
    private static let release = FirmwareRelease(
        id: "v2.7.26.54e0d8d",
        title: "t",
        pageURL: "",
        zipURL: "",
        releaseNotes: "",
        channel: .stable
    )
    private static let heltec = DeviceHardware(
        hwModel: 43, hwModelSlug: "HELTEC_V3", platformioTarget: "heltec-v3", architecture: "esp32-s3",
        activelySupported: true, displayName: "Heltec V3", requiresDfu: nil,
        requiresBootloaderUpgradeForOta: nil, supportLevel: nil
    )
    private static let rak = DeviceHardware(
        hwModel: 9, hwModelSlug: "RAK4631", platformioTarget: "rak4631", architecture: "nrf52840",
        activelySupported: true, displayName: "RAK", requiresDfu: nil,
        requiresBootloaderUpgradeForOta: nil, supportLevel: nil
    )
    private static let base = "https://release.meshtastic.org/2.7.26.54e0d8d/"

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FirmwareRetrieverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private static func md5Hex(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func manifest(name: String, md5: String, bytes: Int) -> Data {
        Data(
            """
            {"version":"2.7.26.54e0d8d","mcu":"esp32s3","files":[
              {"name":"firmware-heltec-v3-2.7.26.54e0d8d.elf","md5":"aa","bytes":1},
              {"name":"\(name)","md5":"\(md5)","bytes":\(bytes),"part_name":"app0"},
              {"name":"littlefs-heltec-v3-2.7.26.54e0d8d.bin","md5":"bb","bytes":2,"part_name":"spiffs"},
              {"name":"mt-esp32s3-ota.bin","md5":"cc","bytes":3,"part_name":"app1"}]}
            """.utf8
        )
    }

    // MARK: - Pure helpers

    @Test("Candidate URLs follow the ESP32 / nRF52 / UF2 lookup order")
    func candidateOrder() {
        let esp = FirmwareRetriever.artifactURLCandidates(release: Self.release, target: "heltec-v3", kind: .espOtaBin)
        #expect(esp.map(\.url.absoluteString) == [
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.mt.json",
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d-update.bin",
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.bin",
        ])
        if case .manifest = esp[0] {} else { Issue.record("first ESP32 candidate must be the manifest") }

        let nrf = FirmwareRetriever.artifactURLCandidates(release: Self.release, target: "rak4631", kind: .nrfOtaZip)
        #expect(nrf.map(\.url.absoluteString) == [Self.base + "firmware-rak4631-2.7.26.54e0d8d-ota.zip"])

        let uf2 = FirmwareRetriever.artifactURLCandidates(release: Self.release, target: "rak4631", kind: .uf2)
        #expect(uf2.map(\.url.absoluteString) == [Self.base + "firmware-rak4631-2.7.26.54e0d8d.uf2"])

        // A legacy release zip is the last resort, with the architecture swapped in.
        let legacy = FirmwareRelease(
            id: "v2.5.0.abc", title: "", pageURL: "",
            zipURL: "https://github.com/x/firmware-esp32-2.5.0.abc.zip", releaseNotes: "", channel: .stable
        )
        let legacyCandidates = FirmwareRetriever.artifactURLCandidates(
            release: legacy, target: "rak4631", kind: .uf2, architecture: "nrf52840"
        )
        #expect(legacyCandidates.last == .releaseZip(URL(string: "https://github.com/x/firmware-nrf52840-2.5.0.abc.zip")!))

        #expect(FirmwareRetriever.artifactURLCandidates(release: Self.release, target: "", kind: .uf2).isEmpty)
    }

    @Test("Manifest app0 entry, mcu, release targets and zip architecture swap")
    func manifestHelpers() {
        let data = Self.manifest(name: "firmware-heltec-v3-2.7.26.54e0d8d.bin", md5: "d7e2dba98f7ecdebdad7bc64550eeae1", bytes: 2_109_248)
        let app0 = FirmwareRetriever.otaEntry(inManifest: data)
        #expect(app0?.name == "firmware-heltec-v3-2.7.26.54e0d8d.bin")
        #expect(app0?.bytes == 2_109_248)
        #expect(app0?.md5 == "d7e2dba98f7ecdebdad7bc64550eeae1")
        #expect(FirmwareRetriever.manifestMcu(data) == "esp32s3")
        #expect(FirmwareRetriever.otaEntry(inManifest: Data(#"{"files":[{"name":"x.bin","part_name":"spiffs"}]}"#.utf8)) == nil)
        #expect(FirmwareRetriever.otaEntry(inManifest: Data("not json".utf8)) == nil)

        let targets = FirmwareRetriever.parseReleaseTargets(Data(
            #"{"version":"2.7.26","targets":[{"board":"rak4631","platform":"nrf52840"},{"board":"Heltec-V3","platform":"esp32s3"}]}"#.utf8
        ))
        #expect(targets == ["rak4631", "heltec-v3"])
        #expect(FirmwareRetriever.parseReleaseTargets(Data("{}".utf8)) == nil)

        #expect(FirmwareRetriever.resolveZipURL("https://x/firmware-esp32-2.5.0.zip", targetArchitecture: "nrf52840")
            == "https://x/firmware-nrf52840-2.5.0.zip")
        #expect(FirmwareRetriever.fileName(target: "heltec-v3", version: "2.7.26.54e0d8d", suffix: "-ota.zip")
            == "firmware-heltec-v3-2.7.26.54e0d8d-ota.zip")
    }

    @Test("Cached artifact lookup matches the download naming")
    func cachedArtifactLookup() throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let retriever = FirmwareRetriever(httpClient: StubFirmwareHTTPClient(responses: [:]), cacheDirectory: cache)
        #expect(retriever.cachedArtifact(release: Self.release, hardware: Self.heltec, kind: .espOtaBin) == nil)

        let releaseDirectory = cache.appendingPathComponent("2.7.26.54e0d8d")
        try FileManager.default.createDirectory(at: releaseDirectory, withIntermediateDirectories: true)
        try Data([1]).write(to: releaseDirectory.appendingPathComponent("firmware-heltec-v3-2.7.26.54e0d8d.bin"))
        try Data([1]).write(to: releaseDirectory.appendingPathComponent("firmware-rak4631-2.7.26.54e0d8d-ota.zip"))
        try Data().write(to: releaseDirectory.appendingPathComponent("firmware-rak4631-2.7.26.54e0d8d.uf2"))

        #expect(retriever.cachedArtifact(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)?
            .lastPathComponent == "firmware-heltec-v3-2.7.26.54e0d8d.bin")
        #expect(retriever.cachedArtifact(release: Self.release, hardware: Self.rak, kind: .nrfOtaZip)?
            .lastPathComponent.hasSuffix("-ota.zip") == true)
        #expect(retriever.cachedArtifact(release: Self.release, hardware: Self.rak, kind: .uf2) == nil)  // empty file
        #expect(retriever.cachedArtifact(release: Self.release, hardware: Self.heltec, kind: .nrfOtaZip) == nil)

        #expect(FirmwareRetriever.cachedFileNames(target: "t", version: "2.0.0", kind: .espOtaBin)
            == ["firmware-t-2.0.0.bin", "firmware-t-2.0.0-update.bin"])
    }

    // MARK: - Download

    @Test("Manifest download verifies MD5 and size, caches and hashes the image")
    func manifestDownloadVerifies() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = Data((0..<1000).map { UInt8($0 % 251) })
        let name = "firmware-heltec-v3-2.7.26.54e0d8d.bin"
        let client = StubFirmwareHTTPClient(responses: [
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.mt.json":
                .init(status: 200, body: Self.manifest(name: name, md5: Self.md5Hex(image).uppercased(), bytes: image.count)),
            Self.base + name: .init(status: 200, body: image),
        ])
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: cache)

        let artifact = try await retriever.download(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)

        #expect(artifact.fileName == name)
        #expect(artifact.size == 1000)
        #expect(artifact.sha256 == Data(SHA256.hash(data: image)))
        #expect(artifact.sha256Hex.count == 64)
        #expect(try Data(contentsOf: artifact.url) == image)
        #expect(!FileManager.default.fileExists(atPath: artifact.url.path + ".part"))
        #expect(artifact.url.deletingLastPathComponent().lastPathComponent == "2.7.26.54e0d8d")

        // Second call reuses the verified cache file; the image itself is not fetched again.
        _ = try await retriever.download(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)
        let imageFetches = await client.requestedURLs.filter { $0 == Self.base + name }.count
        #expect(imageFetches == 1)
    }

    @Test("MD5 mismatch is an error and removes the .part file")
    func md5MismatchRemovesPartFile() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = Data(repeating: 7, count: 64)
        let name = "firmware-heltec-v3-2.7.26.54e0d8d.bin"
        let client = StubFirmwareHTTPClient(responses: [
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.mt.json":
                .init(status: 200, body: Self.manifest(name: name, md5: String(repeating: "0", count: 32), bytes: image.count)),
            Self.base + name: .init(status: 200, body: image),
        ])
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: cache)

        await #expect(throws: FirmwareRetrieverError.verificationFailed(name)) {
            try await retriever.download(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)
        }
        let directory = retriever.releaseDirectory(for: Self.release)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name + ".part").path))
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }

    @Test("Size mismatch against the manifest is rejected")
    func sizeMismatchRejected() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = Data(repeating: 1, count: 10)
        let name = "firmware-heltec-v3-2.7.26.54e0d8d.bin"
        let client = StubFirmwareHTTPClient(responses: [
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.mt.json":
                .init(status: 200, body: Self.manifest(name: name, md5: Self.md5Hex(image), bytes: 11)),
            Self.base + name: .init(status: 200, body: image),
        ])
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: cache)
        await #expect(throws: FirmwareRetrieverError.self) {
            try await retriever.download(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)
        }
    }

    @Test("Without a manifest the -update.bin image is used")
    func fallsBackToUpdateBin() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let image = Data(repeating: 3, count: 32)
        let client = StubFirmwareHTTPClient(responses: [
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d-update.bin": .init(status: 200, body: image),
            Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.bin": .init(status: 200, body: Data(repeating: 9, count: 32)),
        ])
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: cache)

        let artifact = try await retriever.download(release: Self.release, hardware: Self.heltec, kind: .espOtaBin)

        #expect(artifact.fileName == "firmware-heltec-v3-2.7.26.54e0d8d-update.bin")
        #expect(try Data(contentsOf: artifact.url) == image)
        #expect(await client.requestedURLs.first == Self.base + "firmware-heltec-v3-2.7.26.54e0d8d.mt.json")
    }

    @Test("Missing artifact throws not-found and leaves no .part file")
    func missingArtifactThrows() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let retriever = FirmwareRetriever(httpClient: StubFirmwareHTTPClient(responses: [:]), cacheDirectory: cache)

        await #expect(throws: FirmwareRetrieverError.artifactNotFound("firmware-rak4631-2.7.26.54e0d8d.uf2")) {
            try await retriever.download(release: Self.release, hardware: Self.rak, kind: .uf2)
        }
        let leftovers = (try? FileManager.default.contentsOfDirectory(
            atPath: retriever.releaseDirectory(for: Self.release).path
        )) ?? []
        #expect(leftovers.isEmpty)
    }

    @Test("Network errors surface as network failures")
    func networkErrorSurfaces() async throws {
        let cache = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: cache) }
        let client = StubFirmwareHTTPClient(responses: [:], error: URLError(.notConnectedToInternet))
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: cache)
        await #expect {
            try await retriever.download(release: Self.release, hardware: Self.rak, kind: .nrfOtaZip)
        } throws: { error in
            if case FirmwareRetrieverError.network = error { return true }
            return false
        }
    }

    @Test("Release targets come from a JSON zip_url only")
    func releaseTargets() async throws {
        let jsonRelease = FirmwareRelease(
            id: "v2.7.26.54e0d8d", title: "", pageURL: "",
            zipURL: "https://github.com/meshtastic/firmware/releases/download/v2.7.26.54e0d8d/firmware-2.7.26.54e0d8d.json",
            releaseNotes: "", channel: .stable
        )
        let client = StubFirmwareHTTPClient(responses: [
            jsonRelease.zipURL: .init(status: 200, body: Data(#"{"targets":[{"board":"rak4631"}]}"#.utf8)),
        ])
        let retriever = FirmwareRetriever(httpClient: client, cacheDirectory: FileManager.default.temporaryDirectory)

        #expect(await retriever.releaseTargets(for: jsonRelease) == ["rak4631"])
        #expect(await retriever.releaseTargets(for: Self.release) == nil)
    }
}
