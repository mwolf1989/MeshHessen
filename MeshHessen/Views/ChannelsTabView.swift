import SwiftUI

/// "Channels" tab — manage node channels (add, delete, browser).
struct ChannelsTabView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var showAddSheet = false
    @State private var showBrowserSheet = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channels")
                    .font(.headline)
                Spacer()
                Button("Add Mesh Hessen") {
                    Task { await coordinator.addMeshHessenChannel() }
                }
                .buttonStyle(.bordered)

                Button { showBrowserSheet = true } label: {
                    Label("Browse", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)

                Button { showAddSheet = true } label: {
                    Label("Add", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)

            Divider()

            if appState.channels.isEmpty {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Connect to a node to load channel configuration.")
                )
            } else {
                List {
                    ForEach(appState.channels) { channel in
                        ChannelRow(channel: channel)
                    }
                    .onDelete { indexSet in
                        for i in indexSet {
                            Task { await coordinator.deleteChannel(at: i) }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .sheet(isPresented: $showAddSheet) {
            AddChannelSheet()
        }
        .sheet(isPresented: $showBrowserSheet) {
            ChannelBrowserSheet()
        }
    }
}

private struct ChannelRow: View {
    let channel: ChannelInfo

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if channel.id == 0 {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.yellow)
                            .font(.caption)
                    }
                    Text(channel.displayName)
                        .fontWeight(.medium)
                }
                HStack(spacing: 8) {
                    Text("Ch \(channel.id)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(channel.role)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                if channel.uplinkEnabled {
                    Image(systemName: "arrow.up.circle.fill")
                        .foregroundStyle(.green)
                        .help("Uplink enabled")
                }
                if channel.downlinkEnabled {
                    Image(systemName: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                        .help("Downlink enabled")
                }
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }
}
