import SwiftUI

/// Sidebar node list — shown in the NavigationSplitView sidebar.
struct NodeListView: View {
    @Environment(\.appState) private var appState
    @Environment(\.openWindow) private var openWindow
    @Binding var selectedNodeId: UInt32?

    var body: some View {
        List(selection: $selectedNodeId) {
            ForEach(appState.filteredNodes) { node in
                NodeRowView(node: node)
                    .tag(node.id)
                    .contextMenu {
                        Button("Send Direct Message") {
                            appState.ensureDMConversation(for: node.id)
                            appState.dmTargetNodeId = node.id
                            openWindow(id: "dm")
                        }
                        Button("Copy Node ID") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(node.nodeId, forType: .string)
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
            }
        }
        .listStyle(.sidebar)
        .searchable(text: Binding(
            get: { appState.nodeFilter },
            set: { appState.nodeFilter = $0 }
        ), prompt: "Filter nodes")
        .navigationTitle("Nodes (\(appState.filteredNodes.count))")
    }
}

private struct NodeRowView: View {
    let node: NodeInfo

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
                Text(node.name)
                    .font(.callout)
                    .fontWeight(.medium)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if node.snrFloat != 0 {
                        Text(String(format: "%.1f dB", node.snrFloat))
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
        .padding(.vertical, 2)
    }
}
