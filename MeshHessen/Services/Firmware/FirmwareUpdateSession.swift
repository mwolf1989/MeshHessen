import CryptoKit
import Foundation
import Observation

// Windows reference: MeshhessenClient/FirmwareUpdateWindow.xaml.cs, MainWindow.FirmwareUpdate.cs

// MARK: - Transfer phases

/// What the transfer step shows; also the progress events of the updaters.
enum FirmwareTransferPhase: Equatable, Sendable {
    case backup
    case requestingOta
    case enteringBootloader
    case disconnecting
    case searchingLoader
    case connecting(attempt: Int, of: Int)
    case startingOta
    case erasing
    case uploading(Double)
    case validating
    case waitingForDrive
    case waitingForDriveAccess
    case copying(Double)
    case waitingForReboot
    case triggeringBootloader
    case searchingBootloader
    case connectingBootloader(attempt: Int, of: Int)
    case preparingFlash
    case sendingInitPacket
    case retryingUpload(attempt: Int, of: Int)

    var text: String {
        switch self {
        case .backup: String(localized: "Backing up the configuration…")
        case .requestingOta: String(localized: "Asking the device to start its OTA loader…")
        case .enteringBootloader: String(localized: "Asking the device to start its bootloader…")
        case .disconnecting: String(localized: "Releasing the connection to the device…")
        case .searchingLoader: String(localized: "Searching for the OTA loader on the network…")
        case .connecting(let attempt, let total): String(localized: "Connecting to the OTA loader (attempt \(attempt) of \(total))…")
        case .startingOta: String(localized: "Starting the OTA transfer…")
        case .erasing: String(localized: "The device is erasing its update partition…")
        case .uploading: String(localized: "Transferring firmware…")
        case .validating: String(localized: "Waiting for the device to verify the firmware…")
        case .waitingForDrive: String(localized: "Waiting for the boot drive to appear…")
        case .waitingForDriveAccess: String(localized: "Waiting for access to the boot drive…")
        case .copying: String(localized: "Copying firmware to the boot drive…")
        case .waitingForReboot: String(localized: "Waiting for the device to restart…")
        case .triggeringBootloader: String(localized: "Sending the device into its Bluetooth bootloader…")
        case .searchingBootloader: String(localized: "Searching for the bootloader over Bluetooth…")
        case .connectingBootloader(let attempt, let total): String(localized: "Connecting to the bootloader (attempt \(attempt) of \(total))…")
        case .preparingFlash: String(localized: "The bootloader erases the application area (may take 30–60 s)…")
        case .sendingInitPacket: String(localized: "Sending the DFU init packet…")
        case .retryingUpload(let attempt, let total): String(localized: "Retrying the upload (attempt \(attempt) of \(total))…")
        }
    }

    var fraction: Double? {
        switch self {
        case .uploading(let value), .copying(let value): value
        default: nil
        }
    }
}

// MARK: - Device facts

/// Everything the assistant needs to know about the connected device, captured when it opens.
struct FirmwareDeviceFacts: Equatable, Sendable {
    var isConnected = false
    var firmwareVersion: String?
    var pioEnv: String?
    var hwModel = 0
    var hwModelName = ""
    /// 0…100 %, 101 = external power; nil when unknown.
    var batteryLevel: UInt32?
    /// Wi-Fi enabled with an SSID in the device's network config, or the link itself is TCP.
    var wifiConfigured = false
    var connectionType: ConnectionType?
    var tcpHost: String?
}

// MARK: - Pure decisions

enum FirmwareMethodAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
    /// Implemented by a later version of the assistant (Bluetooth methods, plan 026).
    case laterVersion

    var isAvailable: Bool { self == .available }

    var reason: String? {
        switch self {
        case .available: nil
        case .unavailable(let reason): reason
        case .laterVersion: String(localized: "Available in a later version.")
        }
    }
}

struct FirmwareMethodOption: Equatable, Identifiable, Sendable {
    let method: FirmwareUpdateMethod
    let availability: FirmwareMethodAvailability
    var id: String { method.rawValue }
}

enum FirmwareVersionVerdict: Equatable, Sendable {
    case upgrade
    case same
    case downgrade
    case unknown

    var text: String {
        switch self {
        case .upgrade: String(localized: "Upgrade")
        case .same: String(localized: "Same version (reinstall)")
        case .downgrade: String(localized: "Downgrade")
        case .unknown: String(localized: "Version comparison not possible")
        }
    }
}

struct FirmwarePreflightItem: Equatable, Sendable {
    let level: FirmwareInspection.Level
    let text: String

    static func info(_ text: String) -> Self { .init(level: .info, text: text) }
    static func warning(_ text: String) -> Self { .init(level: .warning, text: text) }
    static func error(_ text: String) -> Self { .init(level: .error, text: text) }
}

/// Inputs of the pre-flight page; every field is a plain value so the rules are testable.
struct FirmwarePreflightInput {
    var catalogAvailable = true
    var catalogFromCache = false
    var catalogDate: Date?
    var hardware: DeviceHardware?
    var hardwareFromCatalog = false
    var method: FirmwareUpdateMethod = .wifiOta
    var methodAvailability: FirmwareMethodAvailability = .available
    var facts = FirmwareDeviceFacts()
    var selectedVersion: String?
    var releaseHasTarget: Bool?
    var artifact: FirmwareArtifact?
    var fileError: String?
    var inspection: FirmwareInspection?
}

enum FirmwareWizardLogic {
    /// `AdminMessage.ota_request` exists since firmware 2.7.17.
    static let minimumOtaRequestFirmware = FirmwareVersion(major: 2, minor: 7, patch: 17)
    static let lowBatteryPercent: UInt32 = 30

    /// Method gating of step 2 (Windows `RenderMethodPage`). ESP32 over serial is deliberately not offered
    /// (see `showsWebFlasherHint`).
    static func availableMethods(facts: FirmwareDeviceFacts, hardware: DeviceHardware?) -> [FirmwareMethodOption] {
        let architectureKnown = hardware.map { !$0.architecture.isEmpty } ?? false
        let isEsp = hardware?.isEsp32 ?? false
        let isNrf = hardware?.isNrf52 ?? false
        let isRp = hardware?.isRp2040 ?? false
        let isBluetooth = facts.connectionType == .bluetooth
        let current = FirmwareVersion(facts.firmwareVersion)
        let firmwareSupportsOta = current.map { $0 >= minimumOtaRequestFirmware } ?? true

        let wifi: FirmwareMethodAvailability
        if !facts.isConnected {
            wifi = .unavailable(String(localized: "Requires a connected device."))
        } else if architectureKnown, !isEsp {
            wifi = .unavailable(String(localized: "Only for ESP32 devices."))
        } else if !firmwareSupportsOta {
            wifi = .unavailable(String(localized: "Requires firmware 2.7.17 or newer on the device."))
        } else if !facts.wifiConfigured, facts.connectionType != .tcp {
            wifi = .unavailable(String(localized: "Wi-Fi must be enabled and configured on the device."))
        } else {
            wifi = .available
        }

        let bleOta: FirmwareMethodAvailability
        if !facts.isConnected {
            bleOta = .unavailable(String(localized: "Requires a connected device."))
        } else if architectureKnown, !isEsp {
            bleOta = .unavailable(String(localized: "Only for ESP32 devices."))
        } else if !isBluetooth {
            bleOta = .unavailable(String(localized: "Only while connected to the device over Bluetooth."))
        } else if !firmwareSupportsOta {
            bleOta = .unavailable(String(localized: "Requires firmware 2.7.17 or newer on the device."))
        } else {
            bleOta = .available
        }

        // Also offered without a connection: recovery for a device that already advertises its bootloader.
        let bleDfu: FirmwareMethodAvailability
        if facts.isConnected, architectureKnown, !isNrf {
            bleDfu = .unavailable(String(localized: "Only for nRF52 devices."))
        } else if facts.isConnected, !isBluetooth {
            bleDfu = .unavailable(String(localized: "Only while connected to the device over Bluetooth."))
        } else {
            bleDfu = .available
        }

        let uf2: FirmwareMethodAvailability
        if facts.isConnected, architectureKnown, !(isNrf || isRp) {
            uf2 = .unavailable(String(localized: "Only for nRF52 and RP2040 devices."))
        } else {
            uf2 = .available
        }

        return [
            FirmwareMethodOption(method: .wifiOta, availability: wifi),
            FirmwareMethodOption(method: .bleOta, availability: bleOta),
            FirmwareMethodOption(method: .bleDfu, availability: bleDfu),
            FirmwareMethodOption(method: .uf2, availability: uf2),
        ]
    }

    /// Hardware whose stock bootloader cannot do Bluetooth DFU (catalog `requiresBootloaderUpgradeForOta`).
    static func needsBootloaderUpgradeWarning(hardware: DeviceHardware?, method: FirmwareUpdateMethod?) -> Bool {
        hardware?.requiresBootloaderUpgradeForOta == true && method == .bleDfu
    }

    static let bootloaderGuideURL = "https://meshtastic.org/docs/getting-started/flashing-firmware/nrf52/"

    /// The first available method in display order (Windows default selection).
    static func defaultMethod(_ options: [FirmwareMethodOption]) -> FirmwareUpdateMethod? {
        options.first { $0.availability.isAvailable }?.method
    }

    /// ESP32 on USB without Wi-Fi: point to the web flasher instead of offering serial flashing.
    static func showsWebFlasherHint(facts: FirmwareDeviceFacts, hardware: DeviceHardware?) -> Bool {
        facts.isConnected && (hardware?.isEsp32 ?? false) && facts.connectionType == .serial && !facts.wifiConfigured
    }

    static func versionVerdict(current: String?, selected: String?) -> FirmwareVersionVerdict {
        guard let current = FirmwareVersion(current), let selected = FirmwareVersion(selected) else { return .unknown }
        if selected > current { return .upgrade }
        if selected < current { return .downgrade }
        return .same
    }

    /// Device the catalog knows (exact match), else a placeholder with a guessed architecture.
    static func resolveDevice(
        facts: FirmwareDeviceFacts,
        catalog: FirmwareCatalog?
    ) -> (hardware: DeviceHardware?, fromCatalog: Bool) {
        if let catalog, !catalog.hardware.isEmpty,
           let match = FirmwareCatalogService.resolveHardware(
               hwModel: facts.hwModel,
               pioEnv: facts.pioEnv,
               in: catalog.hardware
           ) {
            return (match, true)
        }
        let pioEnv = facts.pioEnv ?? ""
        guard !facts.hwModelName.isEmpty || !pioEnv.isEmpty else { return (nil, false) }
        let name = facts.hwModelName.isEmpty ? pioEnv : facts.hwModelName
        let guess = FirmwareCatalogService.guessArchitecture(hwModelName: name)
            ?? FirmwareCatalogService.guessArchitecture(hwModelName: pioEnv)
            ?? ""
        return (
            DeviceHardware.unknown(
                hwModel: facts.hwModel,
                hwModelName: name,
                pioEnv: pioEnv.isEmpty ? nil : pioEnv,
                architectureGuess: guess
            ),
            false
        )
    }

    /// Files the prefetch sheet downloads for one device type.
    static func prefetchKinds(for hardware: DeviceHardware) -> [FirmwareArtifactKind] {
        if hardware.isEsp32 { return [.espOtaBin] }
        if hardware.isNrf52 { return [.nrfOtaZip, .uf2] }
        if hardware.isRp2040 { return [.uf2] }
        return []
    }

    /// Rows of the pre-flight page (Windows `RunPreflightAsync`). Any `.error` row blocks the start.
    static func preflightItems(_ input: FirmwarePreflightInput) -> [FirmwarePreflightItem] {
        var items: [FirmwarePreflightItem] = []

        // Catalog and device
        if !input.catalogAvailable {
            items.append(.warning(String(localized: "No firmware catalog available (offline and no cache).")))
        } else if input.catalogFromCache {
            let date = input.catalogDate.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "?"
            items.append(.info(String(localized: "Firmware catalog from cache (\(date)).")))
        } else {
            items.append(.info(String(localized: "Firmware catalog loaded online.")))
        }
        if let hardware = input.hardware, input.catalogAvailable, !hardware.activelySupported {
            items.append(.warning(String(localized: "This device type is not actively supported by Meshtastic.")))
        }
        if let reason = input.methodAvailability.reason {
            items.append(.error(String(localized: "The selected method cannot be used: \(reason)")))
        }
        if needsBootloaderUpgradeWarning(hardware: input.hardware, method: input.method) {
            items.append(.warning(String(localized: "This device usually ships with a bootloader that cannot update over Bluetooth. Update the bootloader once over USB before the first Bluetooth update — otherwise the DFU fails (the device stays usable).")))
        }

        // Firmware file
        if let fileError = input.fileError {
            items.append(.error(fileError))
        } else if let artifact = input.artifact {
            let prefix = String(artifact.sha256Hex.prefix(12))
            items.append(.info(String(localized: "Firmware file \(artifact.fileName), \(artifact.size / 1024) KB, SHA-256 \(prefix)…")))
            if let inspection = input.inspection {
                items += inspection.items.map { FirmwarePreflightItem(level: $0.level, text: $0.message) }
            } else {
                items.append(.error(String(localized: "The firmware file has not been checked.")))
            }
        } else {
            items.append(.error(String(localized: "No firmware file selected.")))
        }
        if input.releaseHasTarget == false {
            let target = input.hardware?.effectiveTarget ?? "?"
            items.append(.warning(String(localized: "The release lists no build for “\(target)”.")))
        }

        // Version verdict
        if let selected = input.selectedVersion {
            let verdict = versionVerdict(current: input.facts.firmwareVersion, selected: selected)
            let line = String(localized: "Firmware \(input.facts.firmwareVersion ?? "?") → \(selected): \(verdict.text)")
            items.append(verdict == .downgrade ? .warning(line) : .info(line))
        }

        // Power
        if input.facts.isConnected, let battery = input.facts.batteryLevel {
            if battery > 100 {
                items.append(.info(String(localized: "Power: external supply.")))
            } else if battery < lowBatteryPercent {
                items.append(.warning(String(localized: "Battery at \(Int(battery)) % and not on external power — charge the device before updating.")))
            } else {
                items.append(.info(String(localized: "Battery at \(Int(battery)) %.")))
            }
        }

        // Method hints
        switch input.method {
        case .wifiOta:
            items.append(.info(String(localized: "Mac and device must be on the same Wi-Fi network.")))
        case .uf2:
            items.append(.info(String(localized: "The device appears as a USB drive; you will be asked to select it so the firmware can be copied.")))
        case .bleOta, .bleDfu:
            items.append(.info(String(localized: "Keep the device close to the Mac. The mesh connection is released and the Mac connects to the loader / bootloader over Bluetooth.")))
        }
        if !input.facts.isConnected {
            items.append(.warning(String(localized: "No device connected: recovery mode. Put the device into its bootloader manually (double-press reset).")))
        }
        return items
    }

    /// The only gate in front of the transfer: a checked file without inspector errors and no red row.
    static func canStart(
        items: [FirmwarePreflightItem],
        artifact: FirmwareArtifact?,
        inspection: FirmwareInspection?
    ) -> Bool {
        guard artifact != nil, let inspection, !inspection.hasErrors else { return false }
        return !items.contains { $0.level == .error }
    }
}

// MARK: - Host

/// What the assistant needs from the app; `AppCoordinator` conforms, tests use a fake.
@MainActor
protocol FirmwareUpdateHost: AnyObject {
    var firmwareDeviceFacts: FirmwareDeviceFacts { get }
    var firmwareUpdateConnectionTarget: (type: ConnectionType, parameters: ConnectionParameters)? { get }
    var firmwareClientNotificationHandler: ((String) -> Void)? { get set }
    /// Firmware version once a reconnect completed its handshake, else nil.
    var reconnectedFirmwareVersion: String? { get }
    func beginFirmwareUpdate()
    func endFirmwareUpdate()
    func disconnectForFirmwareUpdate() async -> (type: ConnectionType, parameters: ConnectionParameters)?
    func reconnectAfterFirmwareUpdate(type: ConnectionType, parameters: ConnectionParameters) async
    func sendFirmwareOtaRequest(mode: UnifiedOta.Mode, sha256: Data) async -> Bool
    func sendFirmwareEnterDfu() async -> Bool
    func exportFirmwareBackup() async throws -> ConfigBackupFile
}

extension AppCoordinator: FirmwareUpdateHost {
    var firmwareDeviceFacts: FirmwareDeviceFacts {
        var facts = FirmwareDeviceFacts()
        let target = firmwareUpdateConnectionTarget
        facts.connectionType = target?.type
        if case .tcp(let host, _)? = target?.parameters { facts.tcpHost = host }
        guard appState.connectionState.isConnected, let info = appState.myNodeInfo else { return facts }
        facts.isConnected = true
        let version = info.firmwareVersion.isEmpty ? protocol_.deviceMetadata?.firmwareVersion : info.firmwareVersion
        facts.firmwareVersion = version?.isEmpty == false ? version : nil
        facts.pioEnv = info.pioEnv.isEmpty ? nil : info.pioEnv
        facts.hwModel = info.hardwareModelRaw
        facts.hwModelName = info.hardwareModel
        if let battery = appState.nodes[info.nodeId]?.batteryLevel, battery > 0 {
            facts.batteryLevel = battery
        }
        let network = protocol_.receivedConfigs[.network]?.network
        facts.wifiConfigured = target?.type == .tcp
            || (network?.wifiEnabled == true && !(network?.wifiSsid.isEmpty ?? true))
        return facts
    }

    var reconnectedFirmwareVersion: String? {
        guard appState.connectionState.isConnected, appState.protocolReady,
              let version = appState.myNodeInfo?.firmwareVersion, !version.isEmpty else { return nil }
        return version
    }

    func sendFirmwareOtaRequest(mode: UnifiedOta.Mode, sha256: Data) async -> Bool {
        switch mode {
        case .wifi: await protocol_.sendOtaRequest(mode: .otaWifi, sha256: sha256)
        case .ble: await protocol_.sendOtaRequest(mode: .otaBle, sha256: sha256)
        }
    }

    func sendFirmwareEnterDfu() async -> Bool {
        await protocol_.enterDfuMode()
    }

    func exportFirmwareBackup() async throws -> ConfigBackupFile {
        try await exportConfigurationBackup(progress: nil)
    }
}

// MARK: - Session

enum FirmwareUpdateError: LocalizedError, Equatable {
    case notReady
    case notConnected
    case dfuRequestNotSent
    case fileChanged
    case methodNotSupported
    case backupFailed(String)
    case bluetoothTargetUnknown

    var errorDescription: String? {
        switch self {
        case .bluetoothTargetUnknown: String(localized: "The Bluetooth device of the current connection is unknown. Connect to the node over Bluetooth first.")
        case .notReady: String(localized: "The pre-flight check has not passed.")
        case .notConnected: String(localized: "The device is not connected.")
        case .dfuRequestNotSent: String(localized: "The bootloader request could not be sent to the device.")
        case .fileChanged: String(localized: "The firmware file changed after the check. Run the check again.")
        case .methodNotSupported: String(localized: "This update method is not available in this version.")
        case .backupFailed(let reason): String(localized: "The configuration backup failed, nothing was sent to the device: \(reason)")
        }
    }
}

/// State machine of the firmware assistant: device & catalog → method → firmware → pre-flight →
/// transfer → done. Nothing is sent to the device before `startConfirmed()` (called only from the UI's
/// confirmation dialog) re-checks `canStart`.
@Observable
@MainActor
final class FirmwareUpdateSession {
    enum Step: Int, CaseIterable {
        case device = 1, method, firmware, preflight, transfer, done
    }

    enum FirmwareSource: Hashable {
        case stable, alpha, local
    }

    enum Outcome: Equatable {
        case success(String)
        case failure(String)
        case cancelled
    }

    @ObservationIgnored let catalogService: FirmwareCatalogService
    @ObservationIgnored let retriever: FirmwareRetriever
    @ObservationIgnored private weak var host: (any FirmwareUpdateHost)?
    /// Asks the user for access to a volume (folder picker pre-pointed at it); returns the granted URL.
    @ObservationIgnored var requestVolumeAccess: (@MainActor (URL?) async -> URL?)?
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var preflightTask: Task<Void, Never>?
    @ObservationIgnored private var manualDrive: URL?
    /// True between `beginFirmwareUpdate()` and the matching end / reconnect.
    @ObservationIgnored private(set) var updateModeActive = false

    var step: Step = .device
    private(set) var facts: FirmwareDeviceFacts
    private(set) var catalog: FirmwareCatalog?
    private(set) var isLoadingCatalog = false
    private(set) var hardware: DeviceHardware?
    private(set) var hardwareFromCatalog = false

    var method: FirmwareUpdateMethod?
    var source: FirmwareSource = .stable
    var selectedRelease: FirmwareRelease?
    private(set) var releaseTargetAvailable: Bool?
    private(set) var localFileURL: URL?
    private(set) var localInspection: FirmwareInspection?
    private(set) var localFileError: String?

    private(set) var isPreparing = false
    private(set) var downloadProgress: Double?
    private(set) var artifact: FirmwareArtifact?
    private(set) var inspection: FirmwareInspection?
    private(set) var fileError: String?
    private(set) var preflightItems: [FirmwarePreflightItem] = []
    var backupFirst = true

    private(set) var isRunning = false
    private(set) var phase: FirmwareTransferPhase?
    private(set) var log: [String] = []
    private(set) var outcome: Outcome?
    private(set) var backupURL: URL?
    private(set) var linkReleased = false
    /// After a successful Bluetooth update: macOS may keep the old pairing / GATT table of the node.
    private(set) var showsBluetoothPairingHint = false
    private(set) var isWaitingForDrive = false
    private(set) var connectionTarget: (type: ConnectionType, parameters: ConnectionParameters)?

    private(set) var isReconnecting = false
    private(set) var reconnectedVersion: String?
    private(set) var reconnectTimedOut = false

    init(
        host: (any FirmwareUpdateHost)?,
        catalogService: FirmwareCatalogService = FirmwareCatalogService(),
        retriever: FirmwareRetriever = FirmwareRetriever()
    ) {
        self.host = host
        self.catalogService = catalogService
        self.retriever = retriever
        facts = host?.firmwareDeviceFacts ?? FirmwareDeviceFacts()
        connectionTarget = host?.firmwareUpdateConnectionTarget
    }

    // MARK: Derived

    var methodOptions: [FirmwareMethodOption] {
        FirmwareWizardLogic.availableMethods(facts: facts, hardware: hardware)
    }

    var methodAvailability: FirmwareMethodAvailability {
        guard let method else { return .unavailable(String(localized: "No method selected.")) }
        return methodOptions.first { $0.method == method }?.availability ?? .laterVersion
    }

    var releases: [FirmwareRelease] {
        switch source {
        case .stable: catalog?.stable ?? []
        case .alpha: catalog?.alpha ?? []
        case .local: []
        }
    }

    func isCachedOffline(_ release: FirmwareRelease) -> Bool {
        guard let hardware, let method else { return false }
        return retriever.cachedArtifact(release: release, hardware: hardware, kind: method.artifactKind) != nil
    }

    var selectedVersion: String? {
        switch source {
        case .local:
            localInspection?.detectedVersion
        case .stable, .alpha:
            selectedRelease?.version
        }
    }

    var canStart: Bool {
        !isRunning && !isPreparing && method != nil
            && FirmwareWizardLogic.canStart(items: preflightItems, artifact: artifact, inspection: inspection)
    }

    var canGoNext: Bool {
        switch step {
        case .device:
            return catalog != nil && !isLoadingCatalog
        case .method:
            return methodAvailability.isAvailable
        case .firmware:
            if source == .local {
                return localFileURL != nil && !(localInspection?.hasErrors ?? true)
            }
            return selectedRelease != nil
        case .preflight, .transfer, .done:
            return false
        }
    }

    var canReconnect: Bool {
        linkReleased && connectionTarget != nil && !isReconnecting && reconnectedVersion == nil
    }

    // MARK: Navigation

    func loadCatalog(forceRefresh: Bool = false) async {
        guard !isRunning else { return }
        isLoadingCatalog = true
        if let host {
            facts = host.firmwareDeviceFacts
            connectionTarget = host.firmwareUpdateConnectionTarget
        }
        let loaded = await catalogService.load(forceRefresh: forceRefresh)
        catalog = loaded
        let resolved = FirmwareWizardLogic.resolveDevice(facts: facts, catalog: loaded)
        hardware = resolved.hardware
        hardwareFromCatalog = resolved.fromCatalog
        if loaded.releases.isEmpty { source = .local }
        isLoadingCatalog = false
    }

    func goNext() {
        guard canGoNext, let next = Step(rawValue: step.rawValue + 1) else { return }
        step = next
        switch next {
        case .method:
            if method == nil || !methodAvailability.isAvailable {
                method = FirmwareWizardLogic.defaultMethod(methodOptions)
            }
        case .firmware:
            if source != .local, selectedRelease == nil || !releases.contains(where: { $0 == selectedRelease }) {
                selectRelease(defaultRelease())
            }
        case .preflight:
            preflightTask?.cancel()
            preflightTask = Task { [weak self] in await self?.runPreflight() }
        case .device, .transfer, .done:
            break
        }
    }

    func goBack() {
        guard !isRunning, step.rawValue > 1, step.rawValue < Step.transfer.rawValue else { return }
        preflightTask?.cancel()
        isPreparing = false
        step = Step(rawValue: step.rawValue - 1) ?? .device
    }

    /// A method change invalidates a local file (different container type).
    func selectMethod(_ newMethod: FirmwareUpdateMethod) {
        guard newMethod != method else { return }
        method = newMethod
        if localFileURL != nil {
            localFileURL = nil
            localInspection = nil
        }
    }

    func selectSource(_ newSource: FirmwareSource) {
        source = newSource
        if newSource != .local { selectRelease(defaultRelease()) }
    }

    func selectRelease(_ release: FirmwareRelease?) {
        selectedRelease = release
        releaseTargetAvailable = nil
        guard let release, let target = hardware?.effectiveTarget, !target.isEmpty else { return }
        Task { [weak self, retriever] in
            let targets = await retriever.releaseTargets(for: release)
            guard let self, self.selectedRelease == release else { return }
            self.releaseTargetAvailable = targets.map { $0.contains(target.lowercased()) }
        }
    }

    /// Takes a user-picked file: copies it out of its security scope into the app's temporary folder and
    /// inspects the copy, so the checked bytes are the bytes that will be sent.
    func selectLocalFile(_ pickedURL: URL) {
        let scoped = pickedURL.startAccessingSecurityScopedResource()
        defer { if scoped { pickedURL.stopAccessingSecurityScopedResource() } }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MeshHessenFirmware", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let copy = directory.appendingPathComponent(pickedURL.lastPathComponent)
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: pickedURL, to: copy)
            localFileURL = copy
            localInspection = inspect(copy)
            localFileError = nil
        } catch {
            localFileURL = nil
            localInspection = nil
            AppLogger.shared.log("[FW] Local file import failed: \(error.localizedDescription)")
            localFileError = error.localizedDescription
        }
    }

    // MARK: Pre-flight

    func runPreflight() async {
        isPreparing = true
        artifact = nil
        inspection = nil
        fileError = nil
        downloadProgress = nil
        preflightItems = []
        defer { isPreparing = false; downloadProgress = nil }

        guard let method else { return }
        if source == .local {
            if let localFileURL {
                do {
                    artifact = try FirmwareRetriever.describe(localFileURL)
                } catch {
                    fileError = String(localized: "The file cannot be read: \(error.localizedDescription)")
                }
            }
        } else if let release = selectedRelease {
            if let hardware {
                do {
                    downloadProgress = 0
                    artifact = try await retriever.download(
                        release: release,
                        hardware: hardware,
                        kind: method.artifactKind
                    ) { [weak self] value in
                        Task { @MainActor in
                            if self?.isPreparing == true { self?.downloadProgress = value }
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    fileError = String(localized: "Download failed: \(error.localizedDescription)")
                }
            } else {
                fileError = String(localized: "The device type is unknown; no firmware can be selected for it.")
            }
        }
        if let artifact { inspection = inspect(artifact.url) }
        refreshPreflightItems()
    }

    private func refreshPreflightItems() {
        guard let method else { return }
        var input = FirmwarePreflightInput()
        input.catalogAvailable = !(catalog?.isEmpty ?? true)
        input.catalogFromCache = catalog?.isFromCache ?? false
        input.catalogDate = catalog?.cacheDate
        input.hardware = hardware
        input.hardwareFromCatalog = hardwareFromCatalog
        input.method = method
        input.methodAvailability = methodAvailability
        input.facts = facts
        input.selectedVersion = source == .local ? inspection?.detectedVersion : selectedRelease?.version
        input.releaseHasTarget = source == .local ? nil : releaseTargetAvailable
        input.artifact = artifact
        input.fileError = fileError
        input.inspection = inspection
        preflightItems = FirmwareWizardLogic.preflightItems(input)
        if !facts.isConnected { backupFirst = false }
    }

    private func inspect(_ url: URL) -> FirmwareInspection? {
        guard let method else { return nil }
        return FirmwareFileInspector.inspect(
            fileURL: url,
            expected: hardware?.firmwareArchitecture ?? .unknown,
            kind: method.artifactKind,
            target: hardware?.effectiveTarget
        )
    }

    // MARK: Transfer

    /// Starts the transfer. Called only from the UI's confirmation dialog; refuses unless `canStart`.
    @discardableResult
    func startConfirmed() -> Bool {
        guard canStart, runTask == nil else {
            AppLogger.shared.log("[FW] Start refused: pre-flight not passed")
            return false
        }
        runTask = Task { [weak self] in
            await self?.run()
            self?.runTask = nil
        }
        return true
    }

    /// Cancels a running transfer (the UI asks first).
    func cancelTransfer() {
        runTask?.cancel()
        manualDrive = nil
    }

    /// Called when the assistant closes: cancels work and restores normal link supervision when the
    /// update mode is still active (e.g. the link was released but the user does not reconnect).
    func close() {
        runTask?.cancel()
        preflightTask?.cancel()
        endUpdateModeIfNeeded()
    }

    func run() async {
        guard let host, let method, let artifact, canStart else {
            outcome = .failure(FirmwareUpdateError.notReady.localizedDescription)
            step = .done
            return
        }
        isRunning = true
        step = .transfer
        outcome = nil
        log = []
        linkReleased = false
        showsBluetoothPairingHint = false

        do {
            // Last gate right before anything is sent: the file on disk must still be the checked one.
            try verifyUnchanged(artifact)

            // The backup runs while heartbeat and watchdog are still active (it takes tens of seconds).
            if backupFirst, facts.isConnected {
                setPhase(.backup)
                do {
                    let file = try await host.exportFirmwareBackup()
                    backupURL = try Self.saveBackup(file)
                    append(String(localized: "Configuration backup saved: \(backupURL?.path ?? "")"))
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    throw FirmwareUpdateError.backupFailed(error.localizedDescription)
                }
            }
            try Task.checkCancellation()

            connectionTarget = host.firmwareUpdateConnectionTarget ?? connectionTarget
            host.beginFirmwareUpdate()
            updateModeActive = true

            switch method {
            case .wifiOta:
                try await runWifiOta(host: host, artifact: artifact)
                outcome = .success(String(localized: "Firmware transferred and verified. The device restarts with the new firmware."))
            case .uf2:
                try await runUf2(host: host, artifact: artifact)
                outcome = .success(String(localized: "Firmware copied. The device restarts with the new firmware."))
            case .bleOta:
                try await runBleOta(host: host, artifact: artifact)
                outcome = .success(String(localized: "Firmware transferred and verified. The device restarts with the new firmware."))
                showsBluetoothPairingHint = true
            case .bleDfu:
                try await runBleDfu(artifact: artifact)
                outcome = .success(String(localized: "Firmware transferred over Bluetooth DFU. The device restarts with the new firmware."))
                showsBluetoothPairingHint = true
            }
            append(String(localized: "Done."))
        } catch is CancellationError {
            append(String(localized: "Cancelled."))
            outcome = .cancelled
        } catch {
            AppLogger.shared.log("[FW] Update failed: \(error.localizedDescription)")
            append("✗ " + error.localizedDescription)
            outcome = .failure(error.localizedDescription)
        }

        // Restore supervision. With the link still up (refused / cancelled before release) the update mode
        // ends now; after a release it ends with the reconnect or when the assistant closes.
        if !linkReleased { endUpdateModeIfNeeded() }
        host.firmwareClientNotificationHandler = nil
        isWaitingForDrive = false
        isRunning = false
        phase = nil
        step = .done
    }

    private func runWifiOta(host: any FirmwareUpdateHost, artifact: FirmwareArtifact) async throws {
        let image = try Data(contentsOf: artifact.url)
        var knownHost: String?
        if case .tcp(let hostname, _)? = connectionTarget?.parameters { knownHost = hostname }
        let dependencies = Esp32WifiOtaUpdater.Dependencies(
            sendOtaRequest: { [weak host] sha in await host?.sendFirmwareOtaRequest(mode: .wifi, sha256: sha) ?? false },
            setNotificationHandler: { [weak host] handler in host?.firmwareClientNotificationHandler = handler },
            releaseMeshLink: { [weak self] in await self?.releaseLink() },
            discoverLoader: { await OtaBeaconListener.discover(timeout: $0) },
            openStream: { address in
                let stream = TcpOtaByteStream(host: address)
                try await stream.connect()
                return stream
            }
        )
        try await Esp32WifiOtaUpdater.perform(
            image: image,
            knownHost: knownHost,
            dependencies: dependencies,
            progress: { [weak self] in self?.setPhase($0) },
            log: { [weak self] in self?.append($0) }
        )
    }

    /// Identifier of the Bluetooth peripheral of the (last) mesh connection, if it was Bluetooth.
    private var bluetoothPeripheralID: UUID? {
        guard case .bluetooth(let address, _)? = connectionTarget?.parameters else { return nil }
        return UUID(uuidString: address)
    }

    /// Reads the file off the main actor and checks it is still the verified one.
    private func readVerifiedBytes(_ artifact: FirmwareArtifact) async throws -> Data {
        let url = artifact.url
        let data = try await Task.detached { try Data(contentsOf: url) }.value
        guard data.count == artifact.size, Data(SHA256.hash(data: data)) == artifact.sha256 else {
            throw FirmwareUpdateError.fileChanged
        }
        return data
    }

    private func runBleOta(host: any FirmwareUpdateHost, artifact: FirmwareArtifact) async throws {
        guard facts.isConnected else { throw FirmwareUpdateError.notConnected }
        guard let meshID = bluetoothPeripheralID else { throw FirmwareUpdateError.bluetoothTargetUnknown }
        let image = try await readVerifiedBytes(artifact)
        let dependencies = Esp32BleOtaUpdater.Dependencies(
            sendOtaRequest: { [weak host] sha in await host?.sendFirmwareOtaRequest(mode: .ble, sha256: sha) ?? false },
            setNotificationHandler: { [weak host] handler in host?.firmwareClientNotificationHandler = handler },
            // From here on the device may be rebooting into its loader: a cancel must not end update mode.
            markRebootRequested: { [weak self] in self?.linkReleased = true },
            releaseMeshLink: { [weak self] in await self?.releaseLink() },
            connectLoader: {
                try await BleGattLink.scanAndConnect(
                    criteria: .esp32Loader(previous: meshID),
                    attempts: Esp32BleOtaUpdater.scanAttempts,
                    timeout: Esp32BleOtaUpdater.scanTimeout,
                    retryDelay: Esp32BleOtaUpdater.scanRetryDelay,
                    tag: "OTA/BLE",
                    notFound: BleOtaError.loaderNotFound
                )
            }
        )
        try await Esp32BleOtaUpdater.perform(
            image: image,
            dependencies: dependencies,
            progress: { [weak self] in self?.setPhase($0) },
            log: { [weak self] in self?.append($0) }
        )
    }

    /// Nordic DFU. Connected: release the mesh link (counts as released from then on), trigger the
    /// buttonless reboot, find the bootloader. Not connected: recovery, the bootloader is already advertising.
    private func runBleDfu(artifact: FirmwareArtifact) async throws {
        let recovery = !facts.isConnected
        let meshID = bluetoothPeripheralID
        if !recovery, meshID == nil { throw FirmwareUpdateError.bluetoothTargetUnknown }
        let archive = try await readVerifiedBytes(artifact)
        let package = try await Task.detached { try DfuPackage(zipData: archive) }.value
        append(String(localized: "DFU package: \(package.binFileName) (\(package.applicationBinary.count / 1024) KB), init packet \(package.initPacket.count) bytes"))

        let dependencies = NordicDfuUpdater.Dependencies(
            releaseMeshLink: { [weak self] in await self?.releaseLink() },
            connectApp: {
                guard let meshID else { throw FirmwareBleError.peripheralNotFound }
                return try await BleGattLink.open(id: meshID)
            },
            scanBootloader: { timeout in
                try await BleGattLink().scan(criteria: .nordicBootloader(previous: meshID), timeout: timeout)
            },
            connectBootloader: { hit in try await BleGattLink.open(id: hit.id) }
        )
        try await NordicDfuUpdater.perform(
            initPacket: package.initPacket,
            firmware: package.applicationBinary,
            alreadyInBootloader: recovery,
            dependencies: dependencies,
            progress: { [weak self] in self?.setPhase($0) },
            log: { [weak self] in self?.append($0) }
        )
    }

    private func runUf2(host: any FirmwareUpdateHost, artifact: FirmwareArtifact) async throws {
        let monitor = Uf2VolumeMonitor()
        defer { monitor.stop() }
        manualDrive = nil

        var drive: URL?
        if facts.isConnected {
            setPhase(.enteringBootloader)
            guard await host.sendFirmwareEnterDfu() else { throw FirmwareUpdateError.dfuRequestNotSent }
            // The device is now rebooting into its bootloader. From here on a cancel must not end
            // update mode (that would re-enable auto-reconnect against the rebooting device); it
            // ends with the reconnect or when the assistant closes, as after a release.
            linkReleased = true
            try await Task.sleep(for: Uf2VolumeFlasher.dfuSettleDelay)
            setPhase(.disconnecting)
            await releaseLink()
            setPhase(.waitingForDrive)
            drive = try await waitForDrive(monitor: monitor, timeout: Uf2VolumeFlasher.connectedWaitTimeout)
        } else {
            setPhase(.waitingForDrive)
            drive = Uf2VolumeFlasher.removableVolumes().first { Uf2VolumeFlasher.readInfo(atVolume: $0) != nil }
            if drive == nil {
                drive = try await waitForDrive(monitor: monitor, timeout: Uf2VolumeFlasher.recoveryWaitTimeout)
            }
        }
        guard let drive else { throw Uf2FlashError.noDrive }
        append(String(localized: "Boot drive detected: \(drive.lastPathComponent)"))

        // The sandbox only lets us write where the user pointed us: confirm the drive in a folder picker.
        let granted: URL
        if let manualDrive, Uf2VolumeMonitor.same(manualDrive, drive) {
            granted = manualDrive
        } else {
            setPhase(.waitingForDriveAccess)
            guard let picked = await requestVolumeAccess?(drive) else { throw Uf2FlashError.accessDenied }
            granted = picked
        }
        try Task.checkCancellation()

        let scoped = granted.startAccessingSecurityScopedResource()
        defer { if scoped { granted.stopAccessingSecurityScopedResource() } }
        guard let info = Uf2VolumeFlasher.readInfo(atVolume: granted) else {
            throw Uf2FlashError.notBootloaderDrive(granted.lastPathComponent)
        }
        append("UF2: \(granted.lastPathComponent) · \(info.summary)")

        try verifyUnchanged(artifact)
        setPhase(.copying(0))
        try await Uf2VolumeFlasher.copy(artifact.url, toVolume: granted) { [weak self] value in
            Task { @MainActor in
                guard let self, case .copying = self.phase else { return }
                self.phase = .copying(value)
            }
        }
        setPhase(.waitingForReboot)

        let deadline = ContinuousClock.now.advanced(by: Uf2VolumeFlasher.detachTimeout)
        while ContinuousClock.now < deadline {
            if monitor.hasUnmounted(granted) {
                append(String(localized: "Boot drive detached — firmware taken by the bootloader."))
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw Uf2FlashError.notConsumed(granted.lastPathComponent)
    }

    /// Lets the user point at the boot drive while the assistant waits for it (recovery mode, or a drive
    /// mounted before the assistant started watching).
    func chooseDriveManually() async {
        guard isWaitingForDrive,
              let picked = await requestVolumeAccess?(URL(fileURLWithPath: "/Volumes", isDirectory: true)) else { return }
        manualDrive = picked
    }

    private func waitForDrive(monitor: Uf2VolumeMonitor, timeout: Duration) async throws -> URL? {
        isWaitingForDrive = true
        defer { isWaitingForDrive = false }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let manualDrive { return manualDrive }
            if let fresh = monitor.newVolumes.first { return fresh }
            try await Task.sleep(for: .milliseconds(500))
        }
        return nil
    }

    private func releaseLink() async {
        guard let host else { return }
        if let target = await host.disconnectForFirmwareUpdate() { connectionTarget = target }
        linkReleased = true
    }

    private func verifyUnchanged(_ artifact: FirmwareArtifact) throws {
        let current = try FirmwareRetriever.describe(artifact.url)
        guard current.sha256 == artifact.sha256, current.size == artifact.size else {
            throw FirmwareUpdateError.fileChanged
        }
        if let check = inspect(artifact.url), check.hasErrors { throw FirmwareUpdateError.notReady }
    }

    private func endUpdateModeIfNeeded() {
        guard updateModeActive else { return }
        updateModeActive = false
        host?.endFirmwareUpdate()
    }

    // MARK: Finish

    /// Reconnects with the previous connection parameters and polls up to 120 s for the new version.
    func reconnect() async {
        guard let host, let target = connectionTarget, !isReconnecting else { return }
        isReconnecting = true
        reconnectTimedOut = false
        reconnectedVersion = nil
        updateModeActive = false
        await host.reconnectAfterFirmwareUpdate(type: target.type, parameters: target.parameters)
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if let version = host.reconnectedFirmwareVersion {
                reconnectedVersion = version
                isReconnecting = false
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        reconnectTimedOut = true
        isReconnecting = false
    }

    // MARK: Helpers

    private func setPhase(_ newPhase: FirmwareTransferPhase) {
        let previousText = phase?.text
        phase = newPhase
        if previousText != newPhase.text { append(newPhase.text) }
    }

    private func append(_ line: String) {
        let stamp = Date().formatted(date: .omitted, time: .standard)
        log.append("[\(stamp)] \(line)")
    }

    private func defaultRelease() -> FirmwareRelease? {
        let list = releases
        if catalog?.isFromCache == true, let cached = list.first(where: isCachedOffline) { return cached }
        return list.first
    }

    /// Writes the backup next to the firmware cache (inside the sandbox container).
    nonisolated static func saveBackup(_ file: ConfigBackupFile, directory: URL = backupDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(file.defaultFileBaseName() + ".json")
        try file.jsonData().write(to: url, options: .atomic)
        return url
    }

    nonisolated static var backupDirectory: URL {
        FirmwareCatalogService.defaultCacheDirectory.appendingPathComponent("backups", isDirectory: true)
    }
}
