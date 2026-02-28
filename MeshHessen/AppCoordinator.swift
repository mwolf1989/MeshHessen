import CoreBluetooth
import CoreData
import Foundation
import SwiftUI

/// Coordinates the connection lifecycle and wires together the app state
/// and protocol service with the active connection service.
@Observable
@MainActor
final class AppCoordinator {
    let appState: AppState
    let router: Router
    let protocol_: MeshtasticProtocolService
    let persistenceController: PersistenceController
    let coreDataStore: MeshCoreDataStore
    let backgroundContext: NSManagedObjectContext
    private var activeConnection: (any ConnectionService)?

    // Persistent BLE service for scanning + connecting
    private let bleService: BluetoothConnectionService = BluetoothConnectionService()
    /// BLE devices discovered during the last scan (updated on MainActor)
    private(set) var discoveredBLEDevices: [DiscoveredBLEDevice] = []

    // Exposed for the serial connection port refresh
    var availableSerialPorts: [String] = []

    // MARK: - Reconnection state

    /// Whether auto-reconnect is enabled (user-configurable)
    var autoReconnectEnabled: Bool = true

    /// The last connection target, stored so we can reconnect to the same device
    private var lastConnectionType: ConnectionType?
    private var lastConnectionParameters: ConnectionParameters?

    /// True when the user explicitly called disconnect — suppresses reconnect
    private var userRequestedDisconnect: Bool = false

    /// Current reconnect attempt count (reset on successful connect)
    private var reconnectAttempt: Int = 0

    /// Active reconnect task (cancelled on explicit disconnect or successful connect)
    private var reconnectTask: Task<Void, Never>?

    /// Active protocol initialization task (cancelled on disconnect/reconnect)
    private var protocolInitializationTask: Task<Void, Never>?

    /// Maximum backoff delay in seconds
    private let maxBackoffSeconds: Int = 30
    private let coreDataMigrationVersionKey = "coreDataMigrationVersion"
    private let coreDataMigrationDateKey = "coreDataMigrationDate"
    private let currentCoreDataMigrationVersion = 2

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.coreDataStore = MeshCoreDataStore(persistenceController: persistenceController)
        self.backgroundContext = persistenceController.newBackgroundContext()
        appState = AppState()
        router = Router()
        router.appState = appState
        protocol_ = MeshtasticProtocolService()
        protocol_.appState = appState
        protocol_.coreDataStore = coreDataStore

        AppLogger.shared.log("[Coordinator] Persistence initialized", debug: true)

        // Listen for debug log notifications (lives for app lifetime, no cleanup needed)
        NotificationCenter.default.addObserver(
            forName: .appLogLine, object: nil, queue: .main
        ) { [weak self] note in
            guard let line = note.userInfo?["line"] as? String else { return }
            // Capture 'self' as a let constant before crossing the Sendable boundary
            let coordinator = self
            Task { @MainActor in
                coordinator?.appState.appendDebugLine(line)
            }
        }

        refreshSerialPorts()

        // Run startup maintenance tasks
        Task.detached { [coreDataStore] in
            // Migrate node color/note from UserDefaults to CoreData
            coreDataStore.migrateNodeCustomizationsFromUserDefaults()
            // Clean up stale nodes
            coreDataStore.clearStaleNodes()
            // Trim old messages
            coreDataStore.trimOldMessages()
        }
    }

    // MARK: - Connect

    func connect(type: ConnectionType, parameters: ConnectionParameters) async {
        // Cancel any pending reconnect before starting a fresh connection
        cancelReconnect()
        cancelProtocolInitialization()
        await teardownActiveConnection()

        userRequestedDisconnect = false
        reconnectAttempt = 0
        lastConnectionType = type
        lastConnectionParameters = parameters

        await performConnect(type: type, parameters: parameters, isReconnect: false)
    }

    // MARK: - Disconnect

    func disconnect() async {
        AppLogger.shared.log("[Coordinator] User requested disconnect", debug: true)
        userRequestedDisconnect = true
        cancelReconnect()
        cancelProtocolInitialization()

        protocol_.disconnect()
        activeConnection?.disconnect()
        activeConnection = nil
        protocol_.connectionService = nil
        appState.connectionState = .disconnected
        appState.protocolReady = false
        appState.protocolStatusMessage = nil
        appState.resetForDisconnect()

        lastConnectionType = nil
        lastConnectionParameters = nil
        AppLogger.shared.log("[Coordinator] Disconnect complete", debug: true)
    }

    // MARK: - Send messages

    func sendMessage(_ text: String, toChannelIndex: Int = 0) async {
        await protocol_.sendTextMessage(text, channelIndex: toChannelIndex)
    }

    func sendDirectMessage(_ text: String, toNodeId: UInt32) async {
        await protocol_.sendTextMessage(text, toNodeId: toNodeId, channelIndex: 0)
    }

    func sendSOSAlert(customText: String? = nil) async {
        await protocol_.sendSOSAlert(customText)
    }

    func updateOwner(shortName: String, longName: String) async {
        await protocol_.setOwner(shortName: shortName, longName: longName)
    }

    // MARK: - Channel management

    func addChannel(name: String, pskBase64: String, uplinkEnabled: Bool, downlinkEnabled: Bool) async {
        AppLogger.shared.log("[Coordinator] Adding channel '\(name)' (index: \(appState.channels.count))", debug: true)
        guard let psk = Data(base64Encoded: pskBase64) else {
            AppLogger.shared.log("[Coordinator] Failed to add channel: invalid PSK", debug: true)
            return
        }
        let idx = appState.channels.count
        await protocol_.setChannel(
            index: idx, name: name, psk: psk,
            isSecondary: idx > 0,
            uplinkEnabled: uplinkEnabled,
            downlinkEnabled: downlinkEnabled
        )
    }

    func deleteChannel(at index: Int) async {
        AppLogger.shared.log("[Coordinator] Deleting channel at index \(index)", debug: true)
        await protocol_.deleteChannel(index: index)
    }

    func addMeshHessenChannel() async {
        AppLogger.shared.log("[Coordinator] Adding Mesh Hessen channel...", debug: true)
        await protocol_.addMeshHessenChannel()
    }

    // MARK: - Serial ports

    func refreshSerialPorts() {
        availableSerialPorts = SerialConnectionService.availablePorts
        AppLogger.shared.log("[Coordinator] Refreshed serial ports: \(availableSerialPorts.count) available", debug: true)
    }

    // MARK: - Bluetooth scanning

    /// Starts a BLE device scan; results appear in `discoveredBLEDevices`.
    func startBLEScanning() {
        discoveredBLEDevices.removeAll()
        bleService.onPeripheralDiscovered = { [weak self] peripheral, rssi in
            // Capture only Sendable values before crossing the concurrency boundary
            let id   = peripheral.identifier
            let name = peripheral.name ?? String(localized: "Unknown Device")
            let rssiInt = rssi.intValue
            Task { @MainActor [weak self] in
                guard let self else { return }
                let dev = DiscoveredBLEDevice(id: id, name: name, rssi: rssiInt)
                if let idx = self.discoveredBLEDevices.firstIndex(where: { $0.id == id }) {
                    self.discoveredBLEDevices[idx].rssi = rssiInt
                } else {
                    self.discoveredBLEDevices.append(dev)
                }
            }
        }
        bleService.startScanning()
        AppLogger.shared.log("[Coordinator] BLE scan started", debug: true)
    }

    /// Stops any ongoing BLE device scan.
    func stopBLEScanning() {
        bleService.stopScanning()
        bleService.onPeripheralDiscovered = nil
        AppLogger.shared.log("[Coordinator] BLE scan stopped", debug: true)
    }

    // MARK: - Message history

    /// Loads previous messages from CoreData into app state.
    /// Falls back to legacy log files only when CoreData is empty.
    /// Called after protocol initialization completes so channel info is available.
    func loadMessageHistory() {
        let logger = MessageLogger.shared

        // Rotate oversized log files on launch
        logger.rotateIfNeeded()

        // One-time import of legacy file-based history into CoreData
        migrateLegacyHistoryIfNeeded(using: logger)

        // Primary: hydrate from CoreData
        let hydration = coreDataStore.hydrate(appState: appState)
        let totalHydrated = hydration.nodes + hydration.channels + hydration.channelMessages + hydration.directMessages
        if totalHydrated > 0 {
            AppLogger.shared.log("[History] CoreData hydration: nodes=\(hydration.nodes), channels=\(hydration.channels), channelMessages=\(hydration.channelMessages), dms=\(hydration.directMessages), unread=\(hydration.conversationsWithUnread)", debug: true)
        }

        // Fallback: load from log files only for channels that still have no messages
        for channel in appState.channels {
            let existing = appState.channelMessages[channel.id]?.count ?? 0
            if existing > 0 { continue }
            let history = logger.loadChannelMessages(channelIndex: channel.id, channelName: channel.name)
            if !history.isEmpty {
                for msg in history {
                    appState.appendMessage(msg)
                }
                AppLogger.shared.log("[History] Fallback: loaded \(history.count) log messages for channel \(channel.name)", debug: true)
            }
        }

        // Fallback: load DM history from log files for conversations without messages
        for dmLog in logger.discoverDMLogFiles() {
            let existing = appState.dmConversations[dmLog.nodeId]?.messages.count ?? 0
            if existing > 0 { continue }
            let history = logger.loadDirectMessages(partnerNodeId: dmLog.nodeId, partnerName: dmLog.name)
            if !history.isEmpty {
                let nodeName = appState.nodes[dmLog.nodeId]?.name ?? dmLog.name
                let colorHex = appState.nodes[dmLog.nodeId]?.colorHex ?? ""
                if appState.dmConversations[dmLog.nodeId] == nil {
                    appState.dmConversations[dmLog.nodeId] = DirectMessageConversation(
                        nodeId: dmLog.nodeId, nodeName: nodeName, colorHex: colorHex
                    )
                }
                for msg in history {
                    appState.dmConversations[dmLog.nodeId]?.messages.append(msg)
                }
                AppLogger.shared.log("[History] Fallback: loaded \(history.count) log DMs for \(nodeName)", debug: true)
            }
        }

        // Persist stale-node cleanup with own node ID now known
        if let myNodeId = appState.myNodeInfo?.nodeId {
            Task.detached { [coreDataStore] in
                coreDataStore.clearStaleNodes(ownNodeId: myNodeId)
            }
        }
    }

    private func migrateLegacyHistoryIfNeeded(using logger: MessageLogger) {
        let defaults = UserDefaults.standard
        let migratedVersion = defaults.integer(forKey: coreDataMigrationVersionKey)
        guard migratedVersion < currentCoreDataMigrationVersion else { return }

        // Version 1: Import legacy log files into CoreData
        if migratedVersion < 1 {
            var importedChannelMessages = 0
            var importedDirectMessages = 0

            for channelLog in logger.discoverChannelLogFiles() {
                let history = logger.loadChannelMessages(
                    channelIndex: channelLog.index,
                    channelName: channelLog.name,
                    limit: 5_000
                )

                for (index, message) in history.enumerated() {
                    var migrated = message
                    migrated.packetId = legacyPacketID(
                        namespace: "channel:\(channelLog.fileName):\(index)",
                        message: message
                    )
                    migrated.channelIndex = channelLog.index
                    migrated.channelName = channelLog.name
                    coreDataStore.upsertMessage(migrated, isDirect: false, partnerNodeId: nil)
                    importedChannelMessages += 1
                }
            }

            for dmLog in logger.discoverDMLogFiles() {
                let history = logger.loadDirectMessages(
                    partnerNodeId: dmLog.nodeId,
                    partnerName: dmLog.name,
                    limit: 5_000
                )

                for (index, message) in history.enumerated() {
                    var migrated = message
                    migrated.packetId = legacyPacketID(
                        namespace: "dm:\(dmLog.fileName):\(index)",
                        message: message
                    )
                    if migrated.toId == 0 {
                        migrated.toId = dmLog.nodeId
                    }
                    coreDataStore.upsertMessage(
                        migrated,
                        isDirect: true,
                        partnerNodeId: dmLog.nodeId,
                        partnerName: dmLog.name
                    )
                    importedDirectMessages += 1
                }
            }

            AppLogger.shared.log(
                "[Migration] v1: Legacy history imported: channels=\(importedChannelMessages), dms=\(importedDirectMessages)",
                debug: true
            )
        }

        // Version 2: Migrate nodeColor_* / nodeNote_* from UserDefaults → CoreData
        if migratedVersion < 2 {
            coreDataStore.migrateNodeCustomizationsFromUserDefaults()
            AppLogger.shared.log("[Migration] v2: UserDefaults node customizations migrated", debug: true)
        }

        defaults.set(currentCoreDataMigrationVersion, forKey: coreDataMigrationVersionKey)
        defaults.set(Date(), forKey: coreDataMigrationDateKey)

        AppLogger.shared.log(
            "[Migration] Completed migration to version \(currentCoreDataMigrationVersion)",
            debug: true
        )
    }

    private func legacyPacketID(namespace: String, message: MessageItem) -> UInt32 {
        let seed = "\(namespace)|\(message.time)|\(message.from)|\(message.message)|\(message.channelIndex)|\(message.channelName)"
        var hash: UInt32 = 2166136261
        for byte in seed.utf8 {
            hash ^= UInt32(byte)
            hash &*= 16777619
        }
        return hash == 0 ? 1 : hash
    }

    // MARK: - Internal: Connection with reconnect support

    /// Performs the actual connection attempt. Shared by initial connect and reconnect.
    private func performConnect(type: ConnectionType, parameters: ConnectionParameters, isReconnect: Bool) async {
        if !isReconnect {
            appState.connectionState = .connecting
        }
        appState.protocolReady = false
        appState.protocolStatusMessage = nil

        let service: any ConnectionService
        switch type {
        case .serial:
            service = SerialConnectionService()
        case .bluetooth:
            // Reuse the persistent BLE service so the already-scanned peripherals are available
            stopBLEScanning()
            service = bleService
        case .tcp:
            service = TcpConnectionService()
        }

        service.onDataReceived = { [weak self] data in
            self?.protocol_.onDataReceived(data)
        }
        service.onConnectionStateChanged = { [weak self] connected in
            Task { @MainActor in
                guard let self else { return }
                if connected {
                    self.appState.connectionState = .connected
                    self.reconnectAttempt = 0
                } else {
                    // Connection dropped — trigger reconnect if appropriate
                    self.handleUnexpectedDisconnect()
                }
            }
        }

        activeConnection = service
        protocol_.connectionService = service

        do {
            try await service.connect(parameters: parameters)
            appState.connectionState = .connected
            appState.protocolReady = false
            appState.protocolStatusMessage = String(localized: "Initializing mesh…")
            reconnectAttempt = 0
            cancelReconnect()
            cancelProtocolInitialization()
            AppLogger.shared.log("[Coordinator] Connected via \(type.rawValue)", debug: true)

            let serviceID = ObjectIdentifier(service)
            protocolInitializationTask = Task { @MainActor [weak self] in
                guard let self else { return }

                let ready = await self.protocol_.initialize()

                guard let active = self.activeConnection,
                      ObjectIdentifier(active) == serviceID,
                      self.appState.connectionState.isConnected
                else { return }

                self.appState.protocolReady = ready
                self.appState.protocolStatusMessage = ready
                    ? nil
                    : (self.appState.protocolStatusMessage ?? String(localized: "Connected, still syncing mesh data…"))

                if !ready {
                    AppLogger.shared.log("[Coordinator] Protocol initialization incomplete; connection stays active")
                }

                self.loadMessageHistory()
                self.protocolInitializationTask = nil
            }
        } catch {
            activeConnection = nil
            protocol_.connectionService = nil
            cancelProtocolInitialization()

            let isPermanent = (error as? ConnectionError)?.isPermanent == true

            if isPermanent {
                // Permanent failure (e.g. permission denied) — never retry, surface the error
                appState.connectionState = .error(error.localizedDescription)
                AppLogger.shared.log("[Coordinator] Permanent connection error (no retry): \(error.localizedDescription)")
            } else if isReconnect {
                // Transient reconnect attempt failed — schedule next attempt
                AppLogger.shared.log("[Coordinator] Reconnect attempt \(reconnectAttempt) failed: \(error.localizedDescription)", debug: true)
                scheduleReconnect()
            } else {
                appState.connectionState = .error(error.localizedDescription)
                AppLogger.shared.log("[Coordinator] Connection error: \(error.localizedDescription)", debug: true)
            }
        }
    }

    // MARK: - Reconnection logic

    /// Called when the connection service reports an unexpected disconnect.
    private func handleUnexpectedDisconnect() {
        guard !userRequestedDisconnect else {
            appState.connectionState = .disconnected
            appState.protocolReady = false
            appState.protocolStatusMessage = nil
            appState.resetForDisconnect()
            return
        }

        // Clean up the dead connection
        activeConnection = nil
        protocol_.connectionService = nil

        guard autoReconnectEnabled,
              lastConnectionType != nil,
              lastConnectionParameters != nil
        else {
            appState.connectionState = .disconnected
            appState.protocolReady = false
            appState.protocolStatusMessage = nil
            appState.resetForDisconnect()
            return
        }

        AppLogger.shared.log("[Coordinator] Unexpected disconnect — will auto-reconnect", debug: true)
        // Don't reset nodes/channels/messages — we want to preserve state across reconnects
        scheduleReconnect()
    }

    /// Schedules the next reconnect attempt with exponential backoff.
    private func scheduleReconnect() {
        guard !userRequestedDisconnect,
              autoReconnectEnabled,
              let type = lastConnectionType,
              let params = lastConnectionParameters
        else { return }

        reconnectAttempt += 1
        let delay = backoffDelay(forAttempt: reconnectAttempt)

        appState.connectionState = .reconnecting(attempt: reconnectAttempt, delaySeconds: delay)
        AppLogger.shared.log("[Coordinator] Reconnect attempt \(reconnectAttempt) in \(delay)s", debug: true)

        reconnectTask = Task { [weak self, attempt = reconnectAttempt] in
            // Countdown: update the status bar every second
            for remaining in stride(from: delay, through: 1, by: -1) {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.appState.connectionState = .reconnecting(attempt: attempt, delaySeconds: remaining)
                }
                try? await Task.sleep(for: .seconds(1))
            }

            guard !Task.isCancelled else { return }

            await MainActor.run {
                self?.appState.connectionState = .connecting
            }

            await self?.performConnect(type: type, parameters: params, isReconnect: true)
        }
    }

    /// Exponential backoff: 1, 2, 4, 8, 16, 30, 30, 30…
    private func backoffDelay(forAttempt attempt: Int) -> Int {
        let raw = pow(2.0, Double(attempt - 1))
        let clamped = min(raw, Double(maxBackoffSeconds))
        return Int(clamped)
    }

    /// Cancels any pending reconnect attempt.
    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func cancelProtocolInitialization() {
        protocolInitializationTask?.cancel()
        protocolInitializationTask = nil
    }

    /// Tears down the active connection without triggering reconnect.
    private func teardownActiveConnection() async {
        let wasAutoReconnect = userRequestedDisconnect
        userRequestedDisconnect = true  // Suppress reconnect during teardown
        cancelProtocolInitialization()
        protocol_.disconnect()
        activeConnection?.disconnect()
        activeConnection = nil
        protocol_.connectionService = nil
        userRequestedDisconnect = wasAutoReconnect
    }
}
