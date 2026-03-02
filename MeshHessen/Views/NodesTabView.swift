import SwiftUI

/// "Nodes" tab — full table view of all nodes with sortable columns.
struct NodesTabView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow
    @State private var sortOrder = [KeyPathComparator(\NodeInfo.name)]
    @State private var selectedNodeId: UInt32?
    @State private var showNodeInfo: NodeInfo?
    @State private var tracerouteTarget: NodeInfo?

    private var sortedNodes: [NodeInfo] {
        let sorted = appState.filteredNodes.sorted(using: sortOrder)
        // Pinned nodes always appear first
        let pinned = sorted.filter { $0.isPinned }
        let unpinned = sorted.filter { !$0.isPinned }
        return pinned + unpinned
    }

    var body: some View {
        Table(sortedNodes, selection: $selectedNodeId, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { node in
                HStack(spacing: 6) {
                    if node.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if !node.colorHex.isEmpty, let color = Color(hex: node.colorHex) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(node.name).lineLimit(1)
                }
            }
            .width(min: 120, ideal: 160)

            TableColumn("Node ID", value: \.nodeId) { node in
                Text(node.nodeId)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(90)

            TableColumn("Short") { node in
                Text(node.shortName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(50)

            TableColumn("Battery", value: \.batteryLevel) { node in
                if node.batteryLevel > 0 {
                    HStack(spacing: 4) {
                        Image(systemName: batteryIcon(Int(node.batteryLevel)))
                        Text("\(node.batteryLevel)%")
                    }
                    .font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(60)

            TableColumn("SNR", value: \.snrFloat) { node in
                if node.snrFloat != 0 {
                    Text(String(format: "%.1f", node.snrFloat))
                        .font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(50)

            TableColumn("Distance", value: \.distanceMeters) { node in
                if node.distanceMeters > 0 {
                    let km = node.distanceMeters / 1000
                    Text(km >= 1
                         ? String(format: "%.1f km", km)
                         : String(format: "%.0f m", node.distanceMeters))
                        .font(.caption)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(70)

            TableColumn("Last Heard", value: \.lastHeard) { node in
                if node.lastHeard > 0 {
                    let date = Date(timeIntervalSince1970: TimeInterval(node.lastHeard))
                    Text(date, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("-").foregroundStyle(.secondary)
                }
            }
            .width(80)

            TableColumn("Note", value: \.note) { node in
                TextField("Notiz…", text: Binding(
                    get: { node.note },
                    set: { newVal in
                        node.note = newVal
                        SettingsService.shared.setNote(newVal, for: node.id)
                    }
                ))
                .textFieldStyle(.plain)
                .font(.caption)
            }
            .width(min: 80, ideal: 130)
        }
        .contextMenu(forSelectionType: UInt32.self) { ids in
            if let id = ids.first, let node = appState.node(forId: id) {
                Button(node.isPinned ? "Unpin" : "Pin") {
                    node.isPinned.toggle()
                    coordinator.coreDataStore.updateNodePinState(nodeId: id, isPinned: node.isPinned)
                }
                Divider()
                Button("Show Info…") { showNodeInfo = node }
                Button("Send Direct Message") {
                    appState.ensureDMConversation(for: id)
                    appState.dmTargetNodeId = id
                    openWindow(id: "dm")
                }
                Button("Copy Node ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(node.nodeId, forType: .string)
                }
                if node.id != appState.myNodeInfo?.nodeId {
                    Button("Traceroute") { tracerouteTarget = node }
                }
                Divider()
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
        } primaryAction: { ids in
            if let id = ids.first { showNodeInfo = appState.node(forId: id) }
        }
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .sheet(item: $tracerouteTarget) { node in
            TracerouteSheet(targetNodeId: node.id, targetName: node.name)
        }
        .navigationTitle("Nodes")
    }

    private func batteryIcon(_ level: Int) -> String {
        switch level {
        case 76...: return "battery.100"
        case 51...: return "battery.75"
        case 26...: return "battery.25"
        default:    return "battery.0"
        }
    }
}
