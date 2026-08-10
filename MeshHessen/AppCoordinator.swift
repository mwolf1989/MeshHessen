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
    @ObservationIgnored let virtualNodeService = VirtualNodeService()
    @ObservationIgnored let mqttProxyService = MqttProxyService()
    private var activeConnection: (any ConnectionService)?

    private(set) var virtualNodeClients: [VirtualNodeService.ClientInfo] = []
    private(set) var virtualNodeError: String?
    private(set) var mqttProxyState: MqttProxyService.State = .stopped
    private var latestMqttConfiguration: Meshtastic_ModuleConfig.MQTTConfig?

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

    /// When true, the next disconnect is expected (e.g. firmware TCP reset after channel write)
    /// and should trigger an immediate reconnect without error UI.
    private var expectingDisconnect: Bool = false
    private var expectedDisconnectTimeoutTask: Task<Void, Never>?
    private var pendingLocalNodeDatabaseReset: Bool = false

    /// Maximum backoff delay in seconds
    private let maxBackoffSeconds: Int = 30
    private let coreDataMigrationVersionKey = "coreDataMigrationVersion"
    private let coreDataMigrationDateKey = "coreDataMigrationDate"
    private let currentCoreDataMigrationVersion = 2

    init(persistenceController: PersistenceController = .shared) {
        self.persistenceController = persistenceController
        self.coreDataStore = MeshCoreDataStore(
            persistenceController: persistenceController,
            isMessageHistoryEnabled: { SettingsService.shared.messageHistoryEnabled }
        )
        self.backgroundContext = persistenceController.newBackgroundContext()
        appState = AppState()
        router = Router()
        router.appState = appState
        protocol_ = MeshtasticProtocolService()
        protocol_.appState = appState
        protocol_.coreDataStore = coreDataStore
        let messageStore = coreDataStore
        appState.onMessageMutation = { message, context in
            messageStore.replaceReactions(for: message, context: context)
        }

        let virtualNodeService = self.virtualNodeService
        protocol_.onFromRadioPayloadReceived = { payload in
            Task {
                try? await virtualNodeService.ingestPhysicalPayload(payload)
            }
        }
        let mqttProxyService = self.mqttProxyService
        protocol_.onMqttProxyMessageReceived = { message in
            Task { await mqttProxyService.ingestRadioMessage(message) }
        }
        protocol_.onMqttConfigurationReceived = { [weak self] configuration in
            Task { @MainActor in
                await self?.applyMqttConfiguration(configuration)
            }
        }

        Task { @MainActor [weak self] in
            await self?.configureAuxiliaryServiceHandlers()
        }

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
            if SettingsService.shared.messageHistoryEnabled {
                let retention = MessageHistoryRetention(
                    rawValue: SettingsService.shared.messageRetentionDays
                ) ?? .ninetyDays
                coreDataStore.enforceMessageRetention(retention)
            }
        }
    }

    // MARK: - Virtual Node / MQTT Proxy

    private func configureAuxiliaryServiceHandlers() async {
        await virtualNodeService.setPhysicalFrameHandler { [weak self] frame in
            guard let self else { throw AuxiliaryServiceError.physicalNodeUnavailable }
            try await self.forwardVirtualNodeFrame(frame)
        }
        await virtualNodeService.setLocalPacketHandler { [weak self] payload in
            await self?.consumeVirtualNodePacket(payload)
        }
        await virtualNodeService.setEventHandler { [weak self] event in
            await self?.handleVirtualNodeEvent(event)
        }

        await mqttProxyService.setRadioMessageHandler { [weak self] message in
            guard let self else { return }
            _ = await self.protocol_.sendMqttProxyMessage(message)
        }
        await mqttProxyService.setStateHandler { [weak self] state in
            await self?.setMqttProxyState(state)
        }
    }

    func applyAuxiliaryServiceSettings() async {
        let settings = SettingsService.shared
        let configuration = VirtualNodeService.Configuration(
            port: UInt16(clamping: settings.virtualNodePort),
            blockAdminCommands: KioskState.shared.effectiveVirtualNodeBlockAdmin
        )
        await virtualNodeService.setBlockAdminCommands(configuration.blockAdminCommands)

        if settings.virtualNodeEnabled, activeConnection?.isConnected == true {
            let currentConfiguration = await virtualNodeService.currentConfiguration()
            if await virtualNodeService.isRunning, currentConfiguration != configuration {
                await virtualNodeService.stop()
            }
            do {
                try await virtualNodeService.start(configuration: configuration)
                virtualNodeError = nil
                virtualNodeClients = await virtualNodeService.connectedClients()
            } catch {
                virtualNodeError = error.localizedDescription
                AppLogger.shared.log("[VirtualNode] \(error.localizedDescription)")
            }
        } else {
            await virtualNodeService.stop()
            virtualNodeClients = []
            virtualNodeError = nil
        }

        if let latestMqttConfiguration {
            await applyMqttConfiguration(latestMqttConfiguration)
        } else if activeConnection?.isConnected != true {
            await mqttProxyService.stop()
        }
    }

    private func applyMqttConfiguration(_ configuration: Meshtastic_ModuleConfig.MQTTConfig) async {
        latestMqttConfiguration = configuration
        guard activeConnection?.isConnected == true, protocol_.currentNodeId != 0 else {
            await mqttProxyService.stop()
            return
        }

        do {
            try await mqttProxyService.start(
                mqttConfig: configuration,
                myNodeID: protocol_.currentNodeId
            )
        } catch {
            AppLogger.shared.log("[MQTT Proxy] \(error.localizedDescription)")
        }
    }

    private func forwardVirtualNodeFrame(_ frame: Data) async throws {
        guard let connection = activeConnection, connection.isConnected else {
            throw AuxiliaryServiceError.physicalNodeUnavailable
        }
        let outgoing = connection.type == .bluetooth
            ? try MeshtasticStreamFrameCodec.payload(from: frame)
            : frame
        try await connection.write(outgoing)
    }

    private func consumeVirtualNodePacket(_ payload: Data) {
        protocol_.onVirtualFromRadioPayload(payload)
    }

    private func handleVirtualNodeEvent(_ event: VirtualNodeService.Event) async {
        switch event {
        case .clientConnected, .clientDisconnected:
            virtualNodeClients = await virtualNodeService.connectedClients()
        case .forwardingFailed(let message), .listenerFailed(let message):
            virtualNodeError = message
        case .started:
            virtualNodeError = nil
        case .stopped:
            virtualNodeClients = []
        case .adminCommandBlocked, .physicalQueueDroppedOldest:
            break
        }
    }

    private func setMqttProxyState(_ state: MqttProxyService.State) {
        mqttProxyState = state
    }

    // MARK: - Connect

    func connect(type: ConnectionType, parameters: ConnectionParameters) async {
        // Cancel any pending reconnect before starting a fresh connection
        cancelReconnect()
        clearExpectedSettingsWriteDisconnect()
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
        clearExpectedSettingsWriteDisconnect()
        cancelProtocolInitialization()

        protocol_.disconnect()
        await virtualNodeService.stop()
        await mqttProxyService.stop()
        virtualNodeClients = []
        mqttProxyState = .stopped
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

    func sendMessage(_ text: String, toChannelIndex: Int = 0, replyToPacketId: UInt32? = nil) async {
        await protocol_.sendTextMessage(
            text,
            channelIndex: toChannelIndex,
            replyToPacketId: replyToPacketId
        )
    }

    func sendDirectMessage(_ text: String, toNodeId: UInt32, replyToPacketId: UInt32? = nil) async {
        await protocol_.sendTextMessage(
            text,
            toNodeId: toNodeId,
            channelIndex: 0,
            replyToPacketId: replyToPacketId
        )
    }

    func sendSOSAlert(customText: String? = nil) async {
        await protocol_.sendSOSAlert(customText)
    }

    func sendEmojiReaction(_ emoji: String, toPacketId: UInt32, toNodeId: UInt32 = 0xFFFFFFFF, channelIndex: Int = 0) async {
        await protocol_.sendEmojiReaction(emoji, toPacketId: toPacketId, toNodeId: toNodeId, channelIndex: channelIndex)
    }

    func sendTraceroute(to nodeId: UInt32) async -> Bool {
        await protocol_.sendTraceroute(to: nodeId)
    }

    var tracerouteResults: [TracerouteResult] {
        protocol_.tracerouteResults
    }

    func updateOwner(shortName: String, longName: String) async {
        await protocol_.setOwner(shortName: shortName, longName: longName)
    }

    @discardableResult
    func setFavorite(
        _ isFavorite: Bool,
        nodeId: UInt32,
        on target: AdminTarget
    ) async throws -> Bool {
        try await protocol_.setFavorite(
            isFavorite,
            nodeId: nodeId,
            on: target,
            timeout: .seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
        )
    }

    // MARK: - Device Configuration

    func requestDeviceConfig() async throws -> MeshtasticProtocolService.DeviceConfigSnapshot {
        try await protocol_.requestAllDeviceConfigs()
    }

    func saveDeviceConfig(
        _ snapshot: MeshtasticProtocolService.DeviceConfigSnapshot,
        replacing original: MeshtasticProtocolService.DeviceConfigSnapshot
    ) async throws -> Bool {
        guard snapshot != original else { return false }

        expectSettingsWriteDisconnect()
        do {
            let didWrite = try await protocol_.saveDeviceConfigs(snapshot, replacing: original)
            guard didWrite else {
                clearExpectedSettingsWriteDisconnect()
                return false
            }

            let changedCategories = MeshtasticProtocolService.changedDeviceConfigCategories(
                snapshot,
                replacing: original
            )
            try await verifyDeviceConfig(snapshot, categories: changedCategories)
            clearExpectedSettingsWriteDisconnect()
            return true
        } catch {
            clearExpectedSettingsWriteDisconnect()
            throw error
        }
    }

    /// Full-schema configuration entry point used by the native local and
    /// remote administration views.
    func requestCompleteConfiguration(
        from target: AdminTarget = .local,
        selection: MeshConfigurationRequestSelection = .all
    ) async throws -> MeshConfigurationSnapshot {
        let timeout = Duration.seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
        return try await protocol_.requestCompleteConfiguration(
            from: target,
            selection: selection,
            timeout: timeout
        )
    }

    @discardableResult
    func saveCompleteConfiguration(
        _ snapshot: MeshConfigurationSnapshot,
        replacing original: MeshConfigurationSnapshot,
        to target: AdminTarget = .local
    ) async throws -> MeshConfigurationDiff {
        let expectedDiff = MeshConfigurationDiff.between(snapshot, and: original)
        guard !expectedDiff.isEmpty else { return expectedDiff }

        if !target.isRemote { expectSettingsWriteDisconnect() }
        do {
            let timeout = Duration.seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
            let writtenDiff = try await protocol_.saveCompleteConfiguration(
                snapshot,
                replacing: original,
                to: target,
                timeout: timeout
            )
            try await verifyCompleteConfiguration(
                snapshot,
                changedLabels: Set(writtenDiff.labels),
                target: target
            )
            if !target.isRemote { clearExpectedSettingsWriteDisconnect() }
            return writtenDiff
        } catch {
            if !target.isRemote { clearExpectedSettingsWriteDisconnect() }
            throw error
        }
    }

    @discardableResult
    func performAdminAction(_ action: AdminNodeAction, on target: AdminTarget) async throws -> Bool {
        let timeout = Duration.seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
        let resetsLocalNodeDatabase = !target.isRemote && action.resetsNodeDatabase
        if !target.isRemote, action.expectsLocalDisconnect {
            expectSettingsWriteDisconnect()
        }
        if resetsLocalNodeDatabase {
            pendingLocalNodeDatabaseReset = true
        }

        do {
            let sent = try await protocol_.performAdminAction(action, on: target, timeout: timeout)
            if resetsLocalNodeDatabase {
                resetLocalNodeDatabaseMirror()
            }
            return sent
        } catch {
            if resetsLocalNodeDatabase {
                clearExpectedSettingsWriteDisconnect()
            }
            throw error
        }
    }

    @discardableResult
    func applyMeshHessenQuickConfiguration(to target: AdminTarget) async throws -> MeshConfigurationDiff {
        if !target.isRemote { expectSettingsWriteDisconnect() }
        do {
            let timeout = Duration.seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
            let diff = try await protocol_.applyMeshHessenQuickConfiguration(to: target, timeout: timeout)
            if !target.isRemote { clearExpectedSettingsWriteDisconnect() }
            return diff
        } catch {
            if !target.isRemote { clearExpectedSettingsWriteDisconnect() }
            throw error
        }
    }

    // MARK: - Channel management

    @discardableResult
    func addChannel(
        name: String,
        pskBase64: String,
        uplinkEnabled: Bool,
        downlinkEnabled: Bool
    ) async throws -> Bool {
        let validatedPSK = try ChannelPSKValidator.validate(pskBase64)
        guard let idx = ChannelSlotAllocator.firstFreeSecondarySlot(
            usedIndices: appState.channels.map(\.id)
        ) else {
            throw ChannelManagementError.noFreeSecondarySlot
        }
        AppLogger.shared.log("[Coordinator] Adding channel '\(name)' (index: \(idx))", debug: true)
        expectSettingsWriteDisconnect()
        let sent = await protocol_.setChannel(
            index: idx, name: name, psk: validatedPSK.data,
            isSecondary: idx > 0,
            uplinkEnabled: uplinkEnabled,
            downlinkEnabled: downlinkEnabled
        )
        guard sent else {
            clearExpectedSettingsWriteDisconnect()
            throw MeshtasticProtocolService.DeviceConfigError.writeFailed(String(localized: "Channel"))
        }
        return true
    }

    func deleteChannel(at index: Int) async {
        AppLogger.shared.log("[Coordinator] Deleting channel at index \(index)", debug: true)
        expectSettingsWriteDisconnect()
        await protocol_.deleteChannel(index: index)
    }

    func addMeshHessenChannel() async {
        AppLogger.shared.log("[Coordinator] Adding Mesh Hessen channel...", debug: true)
        expectSettingsWriteDisconnect()
        await protocol_.addMeshHessenChannel()
    }

    func cleanupDuplicateChannels() async {
        AppLogger.shared.log("[Coordinator] Cleaning up duplicate channels...", debug: true)
        expectSettingsWriteDisconnect()
        await protocol_.cleanupDuplicateChannels()
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

    /// Loads the next older persisted page for a channel and prepends it to
    /// the live message collection without creating duplicates.
    @discardableResult
    func loadOlderChannelMessages(_ channelIndex: Int, limit: Int = 50) -> MessagePage {
        let context = MessageStorageContext.channel(channelIndex)
        let cursor = appState.channelMessages[channelIndex]?.first.map {
            MessagePageCursor(
                createdAt: $0.createdAt,
                persistenceKey: $0.persistenceKey(in: context)
            )
        }
        let page = coreDataStore.fetchChannelMessagePage(
            channelIndex: channelIndex,
            limit: limit,
            before: cursor
        )
        appState.prependChannelMessages(page.messages, channelIndex: channelIndex)
        return page
    }

    /// Loads the next older persisted page for a direct conversation.
    @discardableResult
    func loadOlderDirectMessages(for nodeId: UInt32, limit: Int = 50) -> MessagePage {
        let context = MessageStorageContext.directMessage(partnerNodeId: nodeId)
        let cursor = appState.dmConversations[nodeId]?.messages.first.map {
            MessagePageCursor(
                createdAt: $0.createdAt,
                persistenceKey: $0.persistenceKey(in: context)
            )
        }
        let page = coreDataStore.fetchDirectMessagePage(
            partnerNodeId: nodeId,
            limit: limit,
            before: cursor
        )
        appState.prependDirectMessages(page.messages, partnerNodeId: nodeId)
        return page
    }

    func searchChannelMessages(
        _ query: String,
        scope: ChannelMessageSearchScope
    ) async -> [MessageItem] {
        await coreDataStore.searchChannelMessages(query: query, scope: scope)
    }

    /// Deletes channel history from every persistence layer before returning.
    @discardableResult
    func clearChannelMessages(
        _ channelIndex: Int,
        scope: MessageHistoryDeletionScope = .all
    ) -> Int {
        let referenceDate = Date()
        if let cutoff = scope.cutoffDate(relativeTo: referenceDate) {
            appState.clearChannelMessages(channelIndex, olderThan: cutoff)
        } else {
            appState.clearChannelMessages(channelIndex)
        }
        let deleted = coreDataStore.deleteChannelMessages(
            channelIndex: channelIndex,
            scope: scope,
            relativeTo: referenceDate
        )
        let deletedLogs = scope == .all
            ? MessageLogger.shared.deleteChannelMessages(channelIndex: channelIndex)
            : 0
        AppLogger.shared.log(
            "[History] Deleted \(deleted) channel \(channelIndex) messages and \(deletedLogs) legacy log file(s)",
            debug: true
        )
        return deleted
    }

    /// Deletes direct-message history from every persistence layer before returning.
    @discardableResult
    func clearDirectMessages(
        for nodeId: UInt32,
        scope: MessageHistoryDeletionScope = .all
    ) -> Int {
        let referenceDate = Date()
        if let cutoff = scope.cutoffDate(relativeTo: referenceDate) {
            appState.clearDMMessages(for: nodeId, olderThan: cutoff)
        } else {
            appState.clearDMMessages(for: nodeId)
        }
        let deleted = coreDataStore.deleteConversationMessages(
            partnerNodeId: nodeId,
            scope: scope,
            relativeTo: referenceDate
        )
        let deletedLogs = scope == .all
            ? MessageLogger.shared.deleteDirectMessages(partnerNodeId: nodeId)
            : 0
        let formattedNodeId = String(format: "!%08x", nodeId)
        AppLogger.shared.log(
            "[History] Deleted \(deleted) direct messages for \(formattedNodeId) and \(deletedLogs) legacy log file(s)",
            debug: true
        )
        return deleted
    }

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

        // Guard callbacks against stale services: after reconnect, an old service
        // could fire late and overwrite the new connection's state (race condition).
        let serviceID = ObjectIdentifier(service)

        service.onDataReceived = { [weak self] data in
            Task { @MainActor in
                guard let self, self.activeConnection.map({ ObjectIdentifier($0) }) == serviceID else { return }
                self.protocol_.onDataReceived(data)
            }
        }
        service.onConnectionStateChanged = { [weak self] connected in
            Task { @MainActor in
                guard let self, self.activeConnection.map({ ObjectIdentifier($0) }) == serviceID else { return }
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
                await self.applyAuxiliaryServiceSettings()
                if SettingsService.shared.autoTimeSyncOnConnect {
                    _ = await self.protocol_.synchronizeDeviceTime()
                }
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
        Task { [virtualNodeService, mqttProxyService] in
            await virtualNodeService.stop()
            await mqttProxyService.stop()
        }
        virtualNodeClients = []
        mqttProxyState = .stopped

        if pendingLocalNodeDatabaseReset {
            resetLocalNodeDatabaseMirror()
            pendingLocalNodeDatabaseReset = false
        }

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

        // Settings writes can reboot the firmware — reconnect immediately.
        if expectingDisconnect {
            clearExpectedSettingsWriteDisconnect()
            AppLogger.shared.log("[Coordinator] Expected disconnect after settings write — reconnecting immediately", debug: true)
            reconnectAttempt = 0
            scheduleReconnect()
            return
        }

        AppLogger.shared.log("[Coordinator] Unexpected disconnect — will auto-reconnect", debug: true)
        // Don't reset nodes/channels/messages — we want to preserve state across reconnects
        scheduleReconnect()
    }

    private func expectSettingsWriteDisconnect() {
        expectedDisconnectTimeoutTask?.cancel()
        expectingDisconnect = true
        expectedDisconnectTimeoutTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                return
            }
            guard let self, self.expectingDisconnect else { return }
            self.expectingDisconnect = false
            self.expectedDisconnectTimeoutTask = nil
            self.pendingLocalNodeDatabaseReset = false
            AppLogger.shared.log("[Coordinator] Expected settings-write disconnect did not occur", debug: true)
        }
    }

    private func clearExpectedSettingsWriteDisconnect() {
        expectingDisconnect = false
        expectedDisconnectTimeoutTask?.cancel()
        expectedDisconnectTimeoutTask = nil
        pendingLocalNodeDatabaseReset = false
    }

    private func resetLocalNodeDatabaseMirror() {
        let resetCount = coreDataStore.resetNodeDatabaseMirror()
        appState.resetNodeDatabaseMirror()
        AppLogger.shared.log(
            "[Coordinator] Cleared local NodeDB mirror after device reset (\(resetCount) persisted nodes hidden)"
        )
    }

    private func verifyDeviceConfig(
        _ expected: MeshtasticProtocolService.DeviceConfigSnapshot,
        categories: [String]
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        var lastMismatches: [String] = []

        // Give the firmware time to apply the commit or begin its reboot.
        try await Task.sleep(for: .seconds(1))

        while clock.now < deadline {
            try Task.checkCancellation()

            guard appState.protocolReady, protocol_.connectionService?.isConnected == true else {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }

            do {
                let actual = try await protocol_.requestAllDeviceConfigs(timeout: .seconds(10))
                let mismatches = MeshtasticProtocolService.mismatchedDeviceConfigCategories(
                    actual: actual,
                    expected: expected,
                    categories: categories
                )
                if mismatches.isEmpty { return }
                lastMismatches = mismatches
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A reboot can interrupt the readback. Wait for reconnection and retry.
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        if !lastMismatches.isEmpty {
            throw MeshtasticProtocolService.DeviceConfigError.verificationFailed(lastMismatches)
        }
        throw MeshtasticProtocolService.DeviceConfigError.verificationTimedOut
    }

    private func verifyCompleteConfiguration(
        _ expected: MeshConfigurationSnapshot,
        changedLabels: Set<String>,
        target: AdminTarget
    ) async throws {
        guard !changedLabels.isEmpty else { return }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(60))
        var lastMismatches = changedLabels

        // A commit normally restarts the target. For remote nodes the local
        // transport remains ready; for local nodes this loop naturally waits for
        // AppCoordinator's reconnect sequence to finish.
        try await Task.sleep(for: .seconds(1))
        while clock.now < deadline {
            try Task.checkCancellation()
            guard appState.protocolReady, protocol_.connectionService?.isConnected == true else {
                try await Task.sleep(for: .milliseconds(250))
                continue
            }

            do {
                let timeout = Duration.seconds(SettingsService.shared.remoteAdminTimeoutSeconds)
                let actual = try await protocol_.requestCompleteConfiguration(from: target, timeout: timeout)
                let readbackDiff = MeshConfigurationDiff.between(actual, and: expected)
                let mismatches = Set(readbackDiff.labels).intersection(changedLabels)
                if mismatches.isEmpty { return }
                lastMismatches = mismatches
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A reboot or a renewed remote session can temporarily interrupt
                // readback. Retry until the overall verification deadline.
            }
            try await Task.sleep(for: .milliseconds(500))
        }

        if !lastMismatches.isEmpty {
            throw MeshtasticProtocolService.DeviceConfigError.verificationFailed(lastMismatches.sorted())
        }
        throw MeshtasticProtocolService.DeviceConfigError.verificationTimedOut
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
        await virtualNodeService.stop()
        await mqttProxyService.stop()
        virtualNodeClients = []
        mqttProxyState = .stopped
        protocol_.disconnect()
        activeConnection?.disconnect()
        activeConnection = nil
        protocol_.connectionService = nil
        userRequestedDisconnect = wasAutoReconnect
    }
}

private enum AuxiliaryServiceError: LocalizedError {
    case physicalNodeUnavailable

    var errorDescription: String? {
        String(localized: "No physical Meshtastic node is connected.")
    }
}
