import Foundation
import Testing

@testable import MeshHessen

private func hardware(_ architecture: String, supported: Bool = true, target: String = "board") -> DeviceHardware {
    DeviceHardware(
        hwModel: 1,
        hwModelSlug: target.uppercased(),
        platformioTarget: target,
        architecture: architecture,
        activelySupported: supported,
        displayName: target,
        requiresDfu: nil,
        requiresBootloaderUpgradeForOta: nil,
        supportLevel: nil
    )
}

private func facts(
    connected: Bool = true,
    firmware: String? = "2.7.17.abc",
    wifi: Bool = false,
    type: ConnectionType = .serial,
    battery: UInt32? = nil
) -> FirmwareDeviceFacts {
    var facts = FirmwareDeviceFacts()
    facts.isConnected = connected
    facts.firmwareVersion = firmware
    facts.wifiConfigured = wifi
    facts.connectionType = type
    facts.batteryLevel = battery
    return facts
}

private func availability(
    _ method: FirmwareUpdateMethod,
    _ facts: FirmwareDeviceFacts,
    _ hardware: DeviceHardware?
) -> FirmwareMethodAvailability? {
    FirmwareWizardLogic.availableMethods(facts: facts, hardware: hardware).first { $0.method == method }?.availability
}

private func inspection(_ items: [FirmwareInspection.Item]) -> FirmwareInspection {
    FirmwareInspection(items: items, detectedVersion: nil, detectedChip: nil)
}

private let sampleArtifact = FirmwareArtifact(
    url: URL(fileURLWithPath: "/tmp/firmware-board-2.7.26.bin"),
    size: 2_000_000,
    sha256: Data(repeating: 0xAB, count: 32)
)

@Suite("Firmware wizard logic")
struct FirmwareWizardLogicTests {
    // MARK: Method gating

    @Test("ESP32 with firmware 2.7.16 gets no Wi-Fi OTA")
    func espTooOld() {
        let result = availability(.wifiOta, facts(firmware: "2.7.16.1234", wifi: true), hardware("esp32-s3"))
        #expect(result?.isAvailable == false)
        #expect(result?.reason?.contains("2.7.17") == true)
    }

    @Test("ESP32 with 2.7.17 and Wi-Fi configured gets Wi-Fi OTA")
    func espWifi() {
        #expect(availability(.wifiOta, facts(wifi: true), hardware("esp32-s3")) == .available)
        #expect(availability(.uf2, facts(wifi: true), hardware("esp32-s3"))?.isAvailable == false)
    }

    @Test("ESP32 without Wi-Fi config is refused unless the link itself is TCP")
    func espNeedsWifi() {
        #expect(availability(.wifiOta, facts(wifi: false), hardware("esp32"))?.isAvailable == false)
        #expect(availability(.wifiOta, facts(wifi: false, type: .tcp), hardware("esp32")) == .available)
        #expect(FirmwareWizardLogic.showsWebFlasherHint(facts: facts(wifi: false), hardware: hardware("esp32")))
        #expect(!FirmwareWizardLogic.showsWebFlasherHint(facts: facts(wifi: true), hardware: hardware("esp32")))
    }

    @Test("nRF52 gets UF2, not Wi-Fi OTA")
    func nrf52() {
        let options = FirmwareWizardLogic.availableMethods(facts: facts(wifi: true), hardware: hardware("nrf52840"))
        #expect(options.first { $0.method == .uf2 }?.availability == .available)
        #expect(options.first { $0.method == .wifiOta }?.availability.isAvailable == false)
        #expect(FirmwareWizardLogic.defaultMethod(options) == .uf2)
    }

    @Test("RP2040 gets UF2 only")
    func rp2040() {
        let options = FirmwareWizardLogic.availableMethods(facts: facts(wifi: true), hardware: hardware("rp2040"))
        #expect(options.filter { $0.availability.isAvailable }.map(\.method) == [.uf2])
    }

    @Test("Bluetooth methods are placeholders for a later version")
    func bluetoothLater() {
        let options = FirmwareWizardLogic.availableMethods(facts: facts(type: .bluetooth), hardware: hardware("esp32"))
        #expect(options.first { $0.method == .bleOta }?.availability == .laterVersion)
        #expect(options.first { $0.method == .bleDfu }?.availability == .laterVersion)
    }

    @Test("Not connected: only UF2 (recovery mode)")
    func recovery() {
        let options = FirmwareWizardLogic.availableMethods(facts: facts(connected: false), hardware: nil)
        #expect(options.filter { $0.availability.isAvailable }.map(\.method) == [.uf2])
    }

    @Test("Version verdicts")
    func verdicts() {
        #expect(FirmwareWizardLogic.versionVerdict(current: "2.7.15.aaa", selected: "2.7.26.bbb") == .upgrade)
        #expect(FirmwareWizardLogic.versionVerdict(current: "2.7.26.aaa", selected: "2.7.26.bbb") == .same)
        #expect(FirmwareWizardLogic.versionVerdict(current: "2.7.26", selected: "2.6.11") == .downgrade)
        #expect(FirmwareWizardLogic.versionVerdict(current: nil, selected: "2.6.11") == .unknown)
    }

    @Test("Prefetch kinds per architecture")
    func prefetchKinds() {
        #expect(FirmwareWizardLogic.prefetchKinds(for: hardware("esp32-s3")) == [.espOtaBin])
        #expect(FirmwareWizardLogic.prefetchKinds(for: hardware("nrf52840")) == [.nrfOtaZip, .uf2])
        #expect(FirmwareWizardLogic.prefetchKinds(for: hardware("rp2040")) == [.uf2])
        #expect(FirmwareWizardLogic.prefetchKinds(for: hardware("stm32")).isEmpty)
    }

    @Test("Unknown hardware falls back to a guessed architecture")
    func resolveUnknown() {
        var deviceFacts = facts()
        deviceFacts.hwModelName = "HELTEC_V3"
        deviceFacts.pioEnv = "heltec-v3"
        let resolved = FirmwareWizardLogic.resolveDevice(facts: deviceFacts, catalog: nil)
        #expect(resolved.fromCatalog == false)
        #expect(resolved.hardware?.isEsp32 == true)
        #expect(resolved.hardware?.effectiveTarget == "heltec-v3")
        #expect(FirmwareWizardLogic.resolveDevice(facts: facts(connected: false), catalog: nil).hardware == nil)
    }

    // MARK: Pre-flight

    private func input(
        facts deviceFacts: FirmwareDeviceFacts = facts(wifi: true),
        inspection fileInspection: FirmwareInspection? = inspection([.nameOk(target: "board")]),
        selectedVersion: String? = "2.7.26.abc"
    ) -> FirmwarePreflightInput {
        var input = FirmwarePreflightInput()
        input.hardware = hardware("esp32-s3")
        input.hardwareFromCatalog = true
        input.method = .wifiOta
        input.facts = deviceFacts
        input.selectedVersion = selectedVersion
        input.artifact = sampleArtifact
        input.inspection = fileInspection
        return input
    }

    @Test("A clean pre-flight allows the start")
    func cleanPreflight() {
        let items = FirmwareWizardLogic.preflightItems(input())
        #expect(!items.contains { $0.level == .error })
        #expect(FirmwareWizardLogic.canStart(items: items, artifact: sampleArtifact, inspection: inspection([])))
    }

    @Test("Battery at 20 % without external power is a warning")
    func lowBattery() {
        let items = FirmwareWizardLogic.preflightItems(input(facts: facts(wifi: true, battery: 20)))
        #expect(items.contains { $0.level == .warning && $0.text.contains("20 %") })
        #expect(!items.contains { $0.level == .error })
        let powered = FirmwareWizardLogic.preflightItems(input(facts: facts(wifi: true, battery: 101)))
        #expect(!powered.contains { $0.level == .warning })
    }

    @Test("An inspector error blocks the start")
    func inspectorErrorBlocks() {
        let bad = inspection([.chipMismatch(found: "ESP32", expected: "ESP32-S3")])
        let items = FirmwareWizardLogic.preflightItems(input(inspection: bad))
        #expect(items.contains { $0.level == .error })
        #expect(!FirmwareWizardLogic.canStart(items: items, artifact: sampleArtifact, inspection: bad))
        // Even if the rows were somehow clean, the inspection itself still blocks.
        #expect(!FirmwareWizardLogic.canStart(items: [], artifact: sampleArtifact, inspection: bad))
    }

    @Test("No inspection, no artifact or a download error block the start")
    func missingFileBlocks() {
        let unchecked = FirmwareWizardLogic.preflightItems(input(inspection: nil))
        #expect(unchecked.contains { $0.level == .error })
        #expect(!FirmwareWizardLogic.canStart(items: [], artifact: sampleArtifact, inspection: nil))
        #expect(!FirmwareWizardLogic.canStart(items: [], artifact: nil, inspection: inspection([])))

        var failed = input()
        failed.artifact = nil
        failed.fileError = "Download failed: 404"
        #expect(FirmwareWizardLogic.preflightItems(failed).contains { $0 == .error("Download failed: 404") })
    }

    @Test("A downgrade is a warning")
    func downgrade() {
        let items = FirmwareWizardLogic.preflightItems(input(facts: facts(firmware: "2.7.26.abc", wifi: true), selectedVersion: "2.6.11.def"))
        #expect(items.contains { $0.level == .warning && $0.text.contains("2.6.11") })
        #expect(!items.contains { $0.level == .error })
    }

    @Test("An unavailable method is an error row")
    func unavailableMethod() {
        var blocked = input()
        blocked.methodAvailability = .unavailable("Only for ESP32 devices.")
        #expect(FirmwareWizardLogic.preflightItems(blocked).contains { $0.level == .error })
    }

    @Test("Unsupported hardware and missing release target are warnings")
    func softWarnings() {
        var soft = input()
        soft.hardware = hardware("esp32-s3", supported: false)
        soft.releaseHasTarget = false
        let items = FirmwareWizardLogic.preflightItems(soft)
        #expect(items.filter { $0.level == .warning }.count == 2)
    }
}

// MARK: - Session gate with a fake host (no device, no network)

@MainActor
private final class FakeFirmwareHost: FirmwareUpdateHost {
    var firmwareDeviceFacts = FirmwareDeviceFacts()
    var firmwareUpdateConnectionTarget: (type: ConnectionType, parameters: ConnectionParameters)?
    var firmwareClientNotificationHandler: ((String) -> Void)?
    var reconnectedFirmwareVersion: String?
    var beginCount = 0
    var endCount = 0
    var otaRequests = 0
    var dfuRequests = 0
    var disconnects = 0
    var backups = 0

    func beginFirmwareUpdate() { beginCount += 1 }
    func endFirmwareUpdate() { endCount += 1 }
    func disconnectForFirmwareUpdate() async -> (type: ConnectionType, parameters: ConnectionParameters)? {
        disconnects += 1
        return firmwareUpdateConnectionTarget
    }
    func reconnectAfterFirmwareUpdate(type: ConnectionType, parameters: ConnectionParameters) async {}
    func sendFirmwareOtaRequest(sha256: Data) async -> Bool { otaRequests += 1; return true }
    func sendFirmwareEnterDfu() async -> Bool { dfuRequests += 1; return true }
    func exportFirmwareBackup() async throws -> ConfigBackupFile {
        backups += 1
        throw CancellationError()
    }

    var anythingSent: Bool { beginCount + otaRequests + dfuRequests + disconnects + backups > 0 }
}

@MainActor
@Suite("Firmware update session gate")
struct FirmwareUpdateSessionGateTests {
    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-FwSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func uf2File(in directory: URL, valid: Bool) throws -> URL {
        let url = directory.appendingPathComponent("firmware-rak4631-2.7.26.uf2")
        var block = Data(count: 512)
        if valid {
            func put(_ value: UInt32, _ offset: Int) {
                for index in 0..<4 { block[offset + index] = UInt8((value >> (8 * UInt32(index))) & 0xFF) }
            }
            put(FirmwareFileInspector.uf2MagicStart0, 0)
            put(FirmwareFileInspector.uf2MagicStart1, 4)
            put(FirmwareFileInspector.uf2FlagFamilyId, 8)
            put(0x26000, 12)
            put(UF2Family.nrf52840, 28)
        }
        try block.write(to: url)
        return url
    }

    private func makeSession(_ host: FakeFirmwareHost, cache: URL) -> FirmwareUpdateSession {
        let client = StubFirmwareHTTPClient(responses: [:], error: URLError(.notConnectedToInternet))
        return FirmwareUpdateSession(
            host: host,
            catalogService: FirmwareCatalogService(httpClient: client, cacheDirectory: cache),
            retriever: FirmwareRetriever(httpClient: client, cacheDirectory: cache)
        )
    }

    @Test("A file the inspector rejects is never transmitted")
    func inspectorErrorNeverTransmits() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeFirmwareHost()
        let session = makeSession(host, cache: directory.appendingPathComponent("cache"))
        session.method = .uf2
        session.selectSource(.local)
        session.step = .firmware
        session.selectLocalFile(try uf2File(in: directory, valid: false))
        #expect(session.localInspection?.hasErrors == true)
        #expect(!session.canGoNext)

        await session.runPreflight()
        #expect(session.inspection?.hasErrors == true)
        #expect(session.preflightItems.contains { $0.level == .error })
        #expect(!session.canStart)
        #expect(!session.startConfirmed())
        await session.run()

        #expect(!host.anythingSent)
        #expect(session.outcome == .failure(FirmwareUpdateError.notReady.localizedDescription))
    }

    @Test("Without a pre-flight nothing can start")
    func noPreflightNoStart() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeFirmwareHost()
        let session = makeSession(host, cache: directory)
        session.method = .wifiOta
        #expect(!session.canStart)
        #expect(!session.startConfirmed())
        #expect(!host.anythingSent)
    }

    @Test("A clean UF2 file passes the gate (recovery mode, nothing started)")
    func validFilePassesGate() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeFirmwareHost()
        let session = makeSession(host, cache: directory.appendingPathComponent("cache"))
        session.method = .uf2
        session.selectSource(.local)
        session.step = .firmware
        session.selectLocalFile(try uf2File(in: directory, valid: true))
        #expect(session.localInspection?.hasErrors == false)
        #expect(session.canGoNext)

        await session.runPreflight()
        #expect(session.canStart)
        #expect(!host.anythingSent)
    }

    @Test("Closing without an active update does not touch link supervision")
    func closeWithoutUpdate() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let host = FakeFirmwareHost()
        let session = makeSession(host, cache: directory)
        session.close()
        #expect(host.endCount == 0)
    }
}

// MARK: - Link supervision hooks

private final class IdleConnection: ConnectionService {
    let type: ConnectionType = .serial
    var isConnected = true
    var onDataReceived: ((Data) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?
    private(set) var writes = 0

    func connect(parameters: ConnectionParameters) async throws {}
    func disconnect() { isConnected = false }
    func write(_ data: Data) async throws { writes += 1 }
}

@MainActor
@Suite("Firmware update link supervision")
struct FirmwareLinkSupervisionTests {
    @Test("Supervision can be suspended and resumed; resume needs a live link")
    func suspendResume() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-FwSupervision-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0
        )
        let service = MeshtasticProtocolService(telemetryDatabase: database)

        service.resumeLinkSupervision()
        #expect(!service.isLinkSupervisionActive)

        let connection = IdleConnection()
        service.connectionService = connection
        service.resumeLinkSupervision()
        #expect(service.isLinkSupervisionActive)

        service.suspendLinkSupervision()
        #expect(!service.isLinkSupervisionActive)

        connection.isConnected = false
        service.resumeLinkSupervision()
        #expect(!service.isLinkSupervisionActive)
        #expect(connection.writes == 0)
    }
}
