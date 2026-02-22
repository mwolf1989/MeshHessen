import Foundation
import SwiftUI

/// Coordinates the connection lifecycle and wires together the app state
/// and protocol service with the active connection service.
@Observable
@MainActor
final class AppCoordinator {
    let appState: AppState
    let protocol_: MeshtasticProtocolService
    private var activeConnection: (any ConnectionService)?

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

    /// Maximum backoff delay in seconds
    private let maxBackoffSeconds: Int = 30

    init() {
        appState = AppState()
        protocol_ = MeshtasticProtocolService()
        protocol_.appState = appState

        // Listen for debug log notifications
        NotificationCenter.default.addObserver(
            forName: .appLogLine, object: nil, queue: .main
        ) { [weak self] note in
            guard let line = note.userInfo?["line"] as? String else { return }
            Task { @MainActor in
                self?.appState.appendDebugLine(line)
            }
        }

        refreshSerialPorts()
    }

    // MARK: - Connect

    func connect(type: ConnectionType, parameters: ConnectionParameters) async {
        // Cancel any pending reconnect before starting a fresh connection
        cancelReconnect()
        await teardownActiveConnection()

        userRequestedDisconnect = false
        reconnectAttempt = 0
        lastConnectionType = type
        lastConnectionParameters = parameters

        await performConnect(type: type, parameters: parameters, isReconnect: false)
    }

    // MARK: - Disconnect

    func disconnect() async {
        userRequestedDisconnect = true
        cancelReconnect()

        protocol_.disconnect()
        activeConnection?.disconnect()
        activeConnection = nil
        protocol_.connectionService = nil
        appState.connectionState = .disconnected
        appState.resetForDisconnect()

        lastConnectionType = nil
        lastConnectionParameters = nil
    }

    // MARK: - Send messages

    func sendMessage(_ text: String, toChannelIndex: Int = 0) async {
        await protocol_.sendTextMessage(text, channelIndex: toChannelIndex)
    }

    func sendDirectMessage(_ text: String, toNodeId: UInt32) async {
        await protocol_.sendTextMessage(text, toNodeId: toNodeId, channelIndex: 0)
        // Echo in DM conversation
        let ts = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        let me = MessageItem(
            time: ts,
            from: String(localized: "Me"),
            fromId: appState.myNodeInfo?.nodeId ?? 0,
            toId: toNodeId,
            message: text,
            channelIndex: 0,
            channelName: ""
        )
        appState.addOrUpdateDM(me, myNodeId: appState.myNodeInfo?.nodeId ?? 0)
        // Log outgoing DM
        let partnerName = appState.nodes[toNodeId]?.name ?? String(format: "!%08x", toNodeId)
        MessageLogger.shared.logDirectMessage(me, partnerName: partnerName, partnerNodeId: toNodeId)
    }

    func sendSOSAlert(customText: String? = nil) async {
        await protocol_.sendSOSAlert(customText)
    }

    // MARK: - Channel management

    func addChannel(name: String, pskBase64: String, uplinkEnabled: Bool, downlinkEnabled: Bool) async {
        guard let psk = Data(base64Encoded: pskBase64) else { return }
        let idx = appState.channels.count
        await protocol_.setChannel(
            index: idx, name: name, psk: psk,
            isSecondary: idx > 0,
            uplinkEnabled: uplinkEnabled,
            downlinkEnabled: downlinkEnabled
        )
    }

    func deleteChannel(at index: Int) async {
        await protocol_.deleteChannel(index: index)
    }

    func addMeshHessenChannel() async {
        await protocol_.addMeshHessenChannel()
    }

    // MARK: - Serial ports

    func refreshSerialPorts() {
        availableSerialPorts = SerialConnectionService.availablePorts
    }

    // MARK: - Message history

    /// Loads previous messages from log files into app state.
    /// Called after protocol initialization completes so channel info is available.
    func loadMessageHistory() {
        let logger = MessageLogger.shared

        // Rotate oversized log files on launch
        logger.rotateIfNeeded()

        // Load channel message history
        for channel in appState.channels {
            let existing = appState.channelMessages[channel.id]?.count ?? 0
            if existing > 0 { continue } // Already has live messages, skip
            let history = logger.loadChannelMessages(channelIndex: channel.id, channelName: channel.name)
            if !history.isEmpty {
                for msg in history {
                    appState.appendMessage(msg)
                }
                AppLogger.shared.log("[History] Loaded \(history.count) messages for channel \(channel.name)", debug: true)
            }
        }

        // Load DM conversation history
        for dmLog in logger.discoverDMLogFiles() {
            let existing = appState.dmConversations[dmLog.nodeId]?.messages.count ?? 0
            if existing > 0 { continue } // Already has live messages
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
                AppLogger.shared.log("[History] Loaded \(history.count) DMs for \(nodeName)", debug: true)
            }
        }
    }

    // MARK: - Internal: Connection with reconnect support

    /// Performs the actual connection attempt. Shared by initial connect and reconnect.
    private func performConnect(type: ConnectionType, parameters: ConnectionParameters, isReconnect: Bool) async {
        if !isReconnect {
            appState.connectionState = .connecting
        }

        let service: any ConnectionService
        switch type {
        case .serial:
            service = SerialConnectionService()
        case .bluetooth:
            service = BluetoothConnectionService()
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
            reconnectAttempt = 0
            cancelReconnect()
            AppLogger.shared.log("[Coordinator] Connected via \(type.rawValue)", debug: true)
            // Start the Meshtastic initialization sequence, then load history
            Task {
                await self.protocol_.initialize()
                self.loadMessageHistory()
            }
        } catch {
            activeConnection = nil
            protocol_.connectionService = nil

            if isReconnect {
                // Reconnect attempt failed — schedule next attempt
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
        let raw = Int(pow(2.0, Double(attempt - 1)))
        return min(raw, maxBackoffSeconds)
    }

    /// Cancels any pending reconnect attempt.
    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Tears down the active connection without triggering reconnect.
    private func teardownActiveConnection() async {
        let wasAutoReconnect = userRequestedDisconnect
        userRequestedDisconnect = true  // Suppress reconnect during teardown
        protocol_.disconnect()
        activeConnection?.disconnect()
        activeConnection = nil
        protocol_.connectionService = nil
        userRequestedDisconnect = wasAutoReconnect
    }
}
