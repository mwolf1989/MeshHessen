import SwiftUI

/// Sidebar node list — shown in the NavigationSplitView sidebar.
struct NodeListView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var settings = SettingsService.shared
    @Binding var selectedNodeId: UInt32?
    @State private var ageFilter = NodeAgeFilter.all
    @State private var favoritesOnly = false
    @State private var infrastructureOnly = false
    @State private var directOnly = false
    @State private var hideMqttNodes = false
    @State private var showNodeInfo: NodeInfo?
    @State private var tracerouteTarget: NodeInfo?
    @State private var telemetryTarget: NodeInfo?
    @State private var remoteAdminTarget: NodeInfo?
    @State private var kioskState = KioskState.shared

    private var sortedNodes: [NodeInfo] {
        let filtered = appState.filteredNodes.filter { node in
            ageFilter.includes(lastHeard: node.lastHeard)
                && (!favoritesOnly || node.isFavorite)
                && (!infrastructureOnly || node.isInfrastructure)
                && (!directOnly || node.isDirectRF)
                && (!hideMqttNodes || !node.viaMqtt)
        }
        return settings.nodeSortOrder.sorted(filtered)
    }

    var body: some View {
        List(selection: $selectedNodeId) {
            ForEach(sortedNodes) { node in
                NodeRowView(
                    node: node,
                    isFancy: settings.fancyNodeListEnabled,
                    isColorful: settings.colorfulNodeListEnabled
                )
                    .tag(node.id)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { showNodeInfo = node }
                    .contextMenu {
                        Button("Show Info…") { showNodeInfo = node }
                        Button("Send Direct Message") {
                            appState.ensureDMConversation(for: node.id)
                            appState.dmTargetNodeId = node.id
                            openWindow(id: "dm")
                        }
                        Button("Show on Map") {
                            coordinator.router.navigateToNodeOnMap(nodeNum: node.id)
                        }
                        Button(node.isFavorite ? "Remove Favorite" : "Add Favorite") {
                            Task { await coordinator.protocol_.setFavorite(!node.isFavorite, nodeId: node.id) }
                        }
                        Button(node.isPinned ? "Unpin" : "Pin") {
                            node.isPinned.toggle()
                            coordinator.coreDataStore.updateNodePinState(nodeId: node.id, isPinned: node.isPinned)
                        }
                        if node.id != appState.myNodeInfo?.nodeId {
                            Button("Traceroute") { tracerouteTarget = node }
                        }
                        Button("Telemetry") { telemetryTarget = node }
                        if node.isFavorite, !kioskState.isFeatureLocked(.remoteAdmin) {
                            Button("Remote Administration…") { remoteAdminTarget = node }
                        }
                        Menu("Request Information") {
                            ForEach(NodeInfoRequestType.allCases) { requestType in
                                Button {
                                    Task { await coordinator.protocol_.requestNodeInfo(requestType, from: node.id) }
                                } label: {
                                    Label(requestType.displayName, systemImage: requestType.systemImage)
                                }
                            }
                        }
                        Button("Copy Node ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.nodeId, forType: .string)
                        }
                        Divider()
                        Menu("Sort By") {
                            ForEach(NodeSortOrder.allCases) { sortOrder in
                                Button {
                                    settings.nodeSortOrder = sortOrder
                                } label: {
                                    if settings.nodeSortOrder == sortOrder {
                                        Label(sortOrder.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(sortOrder.displayName)
                                    }
                                }
                            }
                        }
                        Menu("Set Color") {
                            ForEach(nodeColorPresets, id: \.hex) { preset in
                                Button {
                                    node.colorHex = preset.hex
                                    SettingsService.shared.setColorHex(preset.hex, for: node.id)
                                } label: {
                                    Label(preset.name, systemImage: "circle.fill")
                                        .foregroundStyle(Color(hex: preset.hex) ?? .gray)
                                }
                            }
                            Divider()
                            Button("Clear Color") {
                                node.colorHex = ""
                                SettingsService.shared.setColorHex("", for: node.id)
                            }
                        }
                    }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            nodeFilterBar
        }
        .navigationTitle("Nodes (\(sortedNodes.count))")
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .sheet(item: $tracerouteTarget) { node in
            TracerouteSheet(targetNodeId: node.id, targetName: node.name)
        }
        .sheet(item: $telemetryTarget) { node in
            TelemetryView(nodeId: node.id, nodeName: node.name)
        }
        .sheet(item: $remoteAdminTarget) { node in
            RemoteAdminView(nodeID: node.id, nodeName: node.name)
        }
    }

    private var hasAdvancedFilter: Bool {
        ageFilter != .all || favoritesOnly || infrastructureOnly || directOnly || hideMqttNodes
    }

    private var nodeFilterBar: some View {
        HStack(spacing: 6) {
            Menu {
                Picker("Last Heard", selection: $ageFilter) {
                    ForEach(NodeAgeFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                Divider()
                Toggle("Favorites only", isOn: $favoritesOnly)
                Toggle("Infrastructure only", isOn: $infrastructureOnly)
                Toggle("Direct RF only", isOn: $directOnly)
                Toggle("Hide MQTT nodes", isOn: $hideMqttNodes)
            } label: {
                Label("Filter", systemImage: hasAdvancedFilter ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                    .labelStyle(.iconOnly)
            }
            .help("Advanced node filter")

            Menu {
                Picker("Sort By", selection: $settings.nodeSortOrder) {
                    ForEach(NodeSortOrder.allCases) { sortOrder in
                        Text(sortOrder.displayName).tag(sortOrder)
                    }
                }
            } label: {
                Label("Sort", systemImage: "arrow.up.arrow.down.circle")
                    .labelStyle(.iconOnly)
            }
            .help("Sort nodes")

            Toggle(isOn: $settings.fancyNodeListEnabled) {
                Label("Detailed rows", systemImage: "rectangle.grid.1x2")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Show detailed node rows")

            Spacer()

            if hasAdvancedFilter {
                Button("Clear Filters", systemImage: "xmark.circle") {
                    ageFilter = .all
                    favoritesOnly = false
                    infrastructureOnly = false
                    directOnly = false
                    hideMqttNodes = false
                }
                .labelStyle(.iconOnly)
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.bar)
    }
}

private struct NodeRowView: View {
    let node: NodeInfo
    let isFancy: Bool
    let isColorful: Bool

    var body: some View {
        HStack(spacing: 8) {
            // Colored indicator dot
            if let hex = node.colorHex.isEmpty ? nil : node.colorHex {
                Circle()
                    .fill(Color(hex: hex) ?? .gray)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 10, height: 10)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if node.isOwnNode {
                        Image(systemName: "person.crop.circle.fill")
                            .foregroundStyle(Color.accentColor)
                    } else if node.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                    } else if node.isPinned {
                        Image(systemName: "pin.fill")
                            .foregroundStyle(.orange)
                    }
                    Text(node.name)
                        .font(.callout)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }

                HStack(spacing: 4) {
                    if let directSignalText = node.directSignalText {
                        Label(directSignalText, systemImage: "antenna.radiowaves.left.and.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if node.distanceMeters > 0 {
                        let km = node.distanceMeters / 1000
                        Text(km >= 1
                             ? String(format: "%.1f km", km)
                             : String(format: "%.0f m", node.distanceMeters))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if node.lastTracerouteHopCount > 0 {
                        Text(localizedHopCount(node.lastTracerouteHopCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if node.viaMqtt {
                        Label("MQTT", systemImage: "cloud")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if let hopsAway = node.hopsAway, hopsAway > 0 {
                        Text(localizedHopCount(hopsAway))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                if isFancy {
                    HStack(spacing: 6) {
                        if node.batteryLevel > 0 {
                            Label("\(node.batteryLevel)%", systemImage: batteryIcon(node.batteryLevel))
                        }
                        if !node.role.isEmpty {
                            Text(node.role)
                        }
                        if !node.hardwareModel.isEmpty && node.hardwareModel != "Unknown" {
                            Text(node.hardwareModel)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if node.lastHeard > 0 {
                let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                Text(date, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, isFancy ? 5 : 2)
        .padding(.horizontal, isFancy ? 4 : 0)
        .background {
            if isFancy, isColorful, !node.colorHex.isEmpty, let color = Color(hex: node.colorHex) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(color.opacity(0.12))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func batteryIcon(_ level: UInt32) -> String {
        switch level {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }
}
