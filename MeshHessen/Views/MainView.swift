import SwiftUI
import TipKit
import UniformTypeIdentifiers

/// Root view — toolbar + tab-based detail area with alert bell overlay
struct MainView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    @State private var showConnectSheet = false
    @State private var showDeviceConfig = false
    @State private var showTools = false
    @State private var showTDeckWizard = false
    @State private var showTileExport = false
    @State private var showStationNameEditor = false
    @State private var showKioskUnlock = false
    @State private var showDisconnectConfirmation = false
    @State private var selectedNodeId: UInt32?
    @State private var routedNodeInfo: NodeInfo?
    @State private var kioskState = KioskState.shared
    @State private var settings = SettingsService.shared
    @State private var stationNameRevision = 0
    @State private var updateAvailability: UpdateAvailability?
    @State private var pendingNodeKeyMismatches: [NodeKeyMismatch] = []
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    // Export state
    @State private var exportDocument: CsvDocument?
    @State private var exportFileName: String = "export.csv"
    @State private var showExporter = false

    // Tips
    private let connectionTip = ConnectionTip()
    private let messagesTip = MessagesTip()

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                // Sidebar: node list
                VStack(spacing: 0) {
                    // Connection tip when disconnected
                    if !appState.connectionState.isConnected {
                        TipView(connectionTip)
                            .padding(.horizontal, 8)
                            .padding(.top, 4)
                    }
                    if kioskState.isFeatureLocked(.nodes) {
                        ContentUnavailableView(
                            "Nodes Locked",
                            systemImage: "lock.fill",
                            description: Text("Unlock kiosk mode to view the node list.")
                        )
                    } else {
                        NodeListView(selectedNodeId: $selectedNodeId)
                    }
                }
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
            } detail: {
                // Detail: tab view
                VStack(spacing: 0) {
                    tabContent
                }
                .toolbar {
                    mainToolbar
                }
            }

            // Alert Bell Overlay (ZStack over entire window)
            AlertBellOverlay()

            if appState.connectionState.isConnected && !appState.protocolReady {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(appState.protocolStatusMessage ?? String(localized: "Loading mesh data…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 10)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if settings.kioskModeEnabled, kioskState.hasPassword {
                HStack(spacing: 8) {
                    Label(
                        kioskState.isLocked
                            ? String(localized: "Kiosk mode locked")
                            : String(localized: "Kiosk mode unlocked"),
                        systemImage: kioskState.isLocked ? "lock.fill" : "lock.open"
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        if kioskState.isLocked {
                            showKioskUnlock = true
                        } else {
                            kioskState.lock()
                        }
                    } label: {
                        Label(
                            kioskState.isLocked
                                ? String(localized: "Unlock")
                                : String(localized: "Lock"),
                            systemImage: kioskState.isLocked ? "lock.open" : "lock.fill"
                        )
                    }
                    .buttonStyle(.borderless)
                    .help(
                        kioskState.isLocked
                            ? String(localized: "Unlock protected kiosk features")
                            : String(localized: "Lock protected kiosk features")
                    )
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(.bar)
                .overlay(alignment: .top) { Divider() }
            }
        }
        .sheet(isPresented: $showConnectSheet) {
            ConnectSheetView()
        }
        .sheet(isPresented: $showDeviceConfig) {
            DeviceConfigView()
        }
        .sheet(isPresented: $showTools) {
            ToolsView()
        }
        .sheet(isPresented: $showTDeckWizard) {
            TDeckWizardView()
        }
        .sheet(isPresented: $showTileExport) {
            TDeckWizardView(startAtExport: true)
        }
        .sheet(isPresented: $showStationNameEditor) {
            if let node = appState.myNodeInfo {
                StationNameEditorView(node: node) {
                    stationNameRevision &+= 1
                }
            }
        }
        .sheet(isPresented: $showKioskUnlock) {
            KioskUnlockSheet()
        }
        .sheet(item: $routedNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: exportFileName
        ) { result in
            if case .failure(let error) = result {
                AppLogger.shared.log("[Export] Failed: \(error.localizedDescription)")
            }
        }
        .alert("Disconnect?", isPresented: $showDisconnectConfirmation) {
            Button("Disconnect", role: .destructive) {
                Task { await coordinator.disconnect() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Do you really want to disconnect from the connected device?")
        }
        .alert(
            "Node Public Key Changed",
            isPresented: Binding(
                get: { !pendingNodeKeyMismatches.isEmpty },
                set: { _ in }
            ),
            presenting: pendingNodeKeyMismatches.first
        ) { mismatch in
            Button("Accept New Key", role: .destructive) {
                resolveNodeKeyMismatch(mismatch, accept: true)
            }
            Button("Keep Existing Key", role: .cancel) {
                resolveNodeKeyMismatch(mismatch, accept: false)
            }
        } message: { mismatch in
            Text(
                "The public key for \(mismatch.shortName.isEmpty ? String(format: "!%08x", mismatch.nodeId) : mismatch.shortName) changed. Verify this with the node owner before accepting.\n\nOld: \(mismatch.oldKey.base64EncodedString())\nNew: \(mismatch.newKey.base64EncodedString())"
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .nodeKeyMismatchDetected)) { notification in
            guard let mismatch = notification.object as? NodeKeyMismatch,
                  !pendingNodeKeyMismatches.contains(where: { $0.id == mismatch.id })
            else { return }
            pendingNodeKeyMismatches.append(mismatch)
        }
        .onChange(of: coordinator.router.navigationState) { _, navigationState in
            consume(navigationState)
        }
        .onChange(of: kioskState.isLocked) { _, _ in
            if isSelectedTabLocked { appState.selectedTab = .messages }
        }
        .task {
            updateAvailability = await UpdateChecker.shared.checkForUpdate()
        }
    }

    // MARK: - Tab Content

    @ViewBuilder
    private var tabContent: some View {
        TabView(selection: Binding(
            get: { appState.selectedTab },
            set: { appState.selectedTab = $0 }
        )) {
            ChannelTabsView()
                .tabItem { Label("Messages", systemImage: "envelope") }
                .tag(MainTab.messages)

            if !kioskState.isFeatureLocked(.nodes) {
                NodesTabView()
                    .tabItem { Label("Nodes", systemImage: "wifi") }
                    .tag(MainTab.nodes)
            }

            if !kioskState.isFeatureLocked(.channels) {
                ChannelsTabView()
                    .tabItem { Label("Channels", systemImage: "antenna.radiowaves.left.and.right") }
                    .tag(MainTab.channels)
            }

            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(MainTab.map)

            if !kioskState.isFeatureLocked(.debug) {
                DebugView()
                    .tabItem { Label("Debug", systemImage: "ladybug") }
                    .tag(MainTab.debug)
            }

            if !kioskState.isFeatureLocked(.info) {
                InfoView()
                    .tabItem { Label("Info", systemImage: "info.circle") }
                    .tag(MainTab.info)
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        // Left: Connect button
        ToolbarItem(placement: .navigation) {
            Button {
                if appState.connectionState.isConnected {
                    showDisconnectConfirmation = true
                } else {
                    showConnectSheet = true
                }
            } label: {
                Label(
                    appState.connectionState.isConnected ? "Disconnect" : "Connect",
                    systemImage: appState.connectionState.isConnected
                        ? "network.slash" : "network"
                )
            }
            .help(appState.connectionState.isConnected ? "Disconnect from device" : "Connect to device")
        }

        if appState.myNodeInfo != nil {
            ToolbarItem(placement: .navigation) {
                Button {
                    showStationNameEditor = true
                } label: {
                    HStack(spacing: 4) {
                        Text(activeStationName)
                            .lineLimit(1)
                            .foregroundStyle(activeStationNameColor)
                        Image(systemName: "pencil")
                            .font(.caption2)
                    }
                }
                .help("Edit the global or per-node station name")
            }
        }

        // Center: Status
        ToolbarItem(placement: .principal) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let my = appState.myNodeInfo {
                    Text("·")
                        .foregroundStyle(.secondary)
                    Text(my.nodeIdHex)
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }

        ToolbarItem(placement: .automatic) {
            MeshStatusIndicatorsView()
        }

        if let updateAvailability {
            ToolbarItem(placement: .automatic) {
                Link(destination: updateAvailability.releaseURL) {
                    Label(
                        "Update \(updateAvailability.version.description)",
                        systemImage: "arrow.down.circle.fill"
                    )
                    .foregroundStyle(.blue)
                }
                .help("Open the available MeshHessen release on GitHub")
            }
        }

        // Right: DM button
        ToolbarItem(placement: .primaryAction) {
            Button {
                openWindow(id: "dm")
            } label: {
                Label(
                    "Direct Messages",
                    systemImage: appState.dmUnreadCount > 0
                        ? "envelope.badge.fill" : "bubble.left.and.bubble.right"
                )
            }
            .help("Open Direct Messages")
            .overlay(alignment: .topTrailing) {
                if appState.dmUnreadCount > 0 {
                    Text("\(appState.dmUnreadCount)")
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .padding(3)
                        .background(Color.red, in: Circle())
                        .offset(x: 6, y: -6)
                }
            }
        }

        // Device Config
        if !kioskState.isFeatureLocked(.nodeConfiguration) {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showDeviceConfig = true
                } label: {
                    Label("Device Config", systemImage: "gearshape.2")
                }
                .help("Device Configuration")
                .disabled(!appState.protocolReady)
            }
        }

        if !kioskState.isFeatureLocked(.dashboard) {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    openWindow(id: "dashboard")
                } label: {
                    Label("Telemetry Dashboard", systemImage: "rectangle.3.group.bubble.left.fill")
                }
                .help("Open the customizable telemetry dashboard")
            }
        }

        // Export menu
        if !kioskState.isFeatureLocked(.tools) {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Virtual Node / MQTT Status…") {
                        showTools = true
                    }
                    Button("T-Deck Map Assistant…") {
                        showTDeckWizard = true
                    }
                    Button("Export Local Tile Cache as ZIP…") {
                        showTileExport = true
                    }
                } label: {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
                .help("Open map and device tools")
            }

            ToolbarItem(placement: .primaryAction) {
                Menu {
                Button("Export Nodes (CSV)") {
                    let csv = MeshExport.nodesToCsv(Array(appState.nodes.values))
                    exportDocument = CsvDocument(csvData: csv)
                    exportFileName = "meshhessen_nodes.csv"
                    showExporter = true
                }
                Button("Export Messages (CSV)") {
                    let csv = MeshExport.messagesToCsv(appState.allMessages)
                    exportDocument = CsvDocument(csvData: csv)
                    exportFileName = "meshhessen_messages.csv"
                    showExporter = true
                }
                Button("Export Channels (CSV)") {
                    let csv = MeshExport.channelsToCsv(appState.channels)
                    exportDocument = CsvDocument(csvData: csv)
                    exportFileName = "meshhessen_channels.csv"
                    showExporter = true
                }
                Button("Export Positions (CSV)") {
                    let csv = MeshExport.positionsToCsv(Array(appState.nodes.values))
                    exportDocument = CsvDocument(csvData: csv)
                    exportFileName = "meshhessen_positions.csv"
                    showExporter = true
                }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export mesh data as CSV")
            }
        }
    }

    // MARK: - Helpers

    private var statusColor: Color {
        if appState.connectionState.isConnected && !appState.protocolReady {
            return .yellow
        }

        switch appState.connectionState {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .reconnecting: return .orange
        case .disconnected: return .gray
        case .error:        return .red
        }
    }

    private var activeStationName: String {
        _ = stationNameRevision
        guard let node = appState.myNodeInfo else { return "" }
        let global = settings.stationName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !global.isEmpty { return global }
        let perNode = settings.stationName(for: node.nodeId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !perNode.isEmpty { return perNode }
        let shortName = node.shortName.trimmingCharacters(in: .whitespacesAndNewlines)
        return shortName.isEmpty ? node.nodeIdHex : shortName
    }

    private var activeStationNameColor: Color {
        guard let node = appState.myNodeInfo else { return .secondary }
        if !settings.stationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .red
        }
        if !settings.stationName(for: node.nodeId).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .orange
        }
        return .secondary
    }

    private func resolveNodeKeyMismatch(_ mismatch: NodeKeyMismatch, accept: Bool) {
        _ = NodeKeyService.shared.resolve(mismatch, acceptNewKey: accept)
        pendingNodeKeyMismatches.removeAll { $0.id == mismatch.id }
    }

    private var statusText: String {
        if appState.connectionState.isConnected && !appState.protocolReady {
            return appState.protocolStatusMessage ?? String(localized: "Connected (initializing…)")
        }
        return appState.connectionState.displayText
    }

    private func consume(_ navigationState: NavigationState) {
        if navigationState.selectedTab == .nodes, kioskState.isFeatureLocked(.nodes) {
            appState.selectedTab = .messages
            return
        }
        if navigationState.selectedTab == .channels, kioskState.isFeatureLocked(.channels) {
            appState.selectedTab = .messages
            return
        }
        if navigationState.selectedTab == .debug, kioskState.isFeatureLocked(.debug) {
            appState.selectedTab = .messages
            return
        }
        if navigationState.selectedTab == .info, kioskState.isFeatureLocked(.info) {
            appState.selectedTab = .messages
            return
        }
        switch navigationState.messages {
        case .channels(let channelId, _):
            if let channelId { appState.selectedChannelIndex = channelId }
        case .directMessages(let userNum, _):
            if let userNum {
                appState.ensureDMConversation(for: userNum)
                appState.dmTargetNodeId = userNum
                openWindow(id: "dm")
            }
        case nil:
            break
        }

        if let nodeId = navigationState.nodeListSelectedNodeNum {
            selectedNodeId = nodeId
            routedNodeInfo = appState.node(forId: nodeId)
        }

        if case .selectedNode(let nodeId) = navigationState.map {
            appState.mapFocusNodeId = nodeId
        }

        if navigationState.selectedTab == .settings, !kioskState.isFeatureLocked(.settings) {
            openSettings()
        }
    }

    private var isSelectedTabLocked: Bool {
        switch appState.selectedTab {
        case .nodes: return kioskState.isFeatureLocked(.nodes)
        case .channels: return kioskState.isFeatureLocked(.channels)
        case .debug: return kioskState.isFeatureLocked(.debug)
        case .info: return kioskState.isFeatureLocked(.info)
        case .messages, .map: return false
        }
    }
}

#Preview {
    MainView()
        .environment(\.appState, AppState())
        .environment(AppCoordinator())
}
