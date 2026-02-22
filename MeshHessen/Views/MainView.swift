import SwiftUI

/// Root view — toolbar + tab-based detail area with alert bell overlay
struct MainView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    @State private var showConnectSheet = false
    @State private var selectedNodeId: UInt32?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ZStack(alignment: .top) {
            NavigationSplitView {
                // Sidebar: node list
                NodeListView(selectedNodeId: $selectedNodeId)
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
        .sheet(isPresented: $showConnectSheet) {
            ConnectSheetView()
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

            NodesTabView()
                .tabItem { Label("Nodes", systemImage: "wifi") }
                .tag(MainTab.nodes)

            ChannelsTabView()
                .tabItem { Label("Channels", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(MainTab.channels)

            MapView()
                .tabItem { Label("Map", systemImage: "map") }
                .tag(MainTab.map)

            DebugView()
                .tabItem { Label("Debug", systemImage: "ladybug") }
                .tag(MainTab.debug)

            InfoView()
                .tabItem { Label("Info", systemImage: "info.circle") }
                .tag(MainTab.info)
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        // Left: Connect button
        ToolbarItem(placement: .navigation) {
            Button {
                if appState.connectionState.isConnected {
                    Task { await coordinator.disconnect() }
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

    private var statusText: String {
        if appState.connectionState.isConnected && !appState.protocolReady {
            return appState.protocolStatusMessage ?? String(localized: "Connected (initializing…)")
        }
        return appState.connectionState.displayText
    }
}

#Preview {
    MainView()
        .environment(\.appState, AppState())
        .environment(AppCoordinator())
}
