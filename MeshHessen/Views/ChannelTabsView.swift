import SwiftUI

/// "Messages" tab — per-channel tab strip with ChannelChatView per channel.
struct ChannelTabsView: View {
    @Environment(\.appState) private var appState
    @State private var selectedTabID = -1

    var body: some View {
        if appState.channels.isEmpty {
            if appState.connectionState.isConnected && !appState.protocolReady {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.large)
                    Text(appState.protocolStatusMessage ?? String(localized: "Loading mesh data…"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView(
                    "No Channels",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Connect to a node to load channels.")
                )
            }
        } else {
            TabView(selection: $selectedTabID) {
                AllChannelsChatView()
                    .tabItem {
                        Label("All Channels", systemImage: "text.bubble.fill")
                    }
                    .tag(-1)

                ForEach(appState.channels) { channel in
                    ChannelChatView(channelIndex: channel.id)
                        .tabItem {
                            Label {
                                let unread = appState.channelUnreadCounts[channel.id] ?? 0
                                Text(channel.displayName + (unread > 0 ? " (\(unread))" : ""))
                            } icon: {
                                Image(systemName: channel.id == 0 ? "star.fill" : "bubble.left")
                            }
                        }
                        .tag(channel.id)
                }
            }
            .tabViewStyle(.automatic)
            .onAppear {
                if appState.channels.contains(where: { $0.id == appState.selectedChannelIndex }) {
                    selectedTabID = appState.selectedChannelIndex
                }
            }
            .onChange(of: selectedTabID) { _, newValue in
                guard newValue >= 0,
                      appState.channels.contains(where: { $0.id == newValue })
                else { return }
                appState.selectedChannelIndex = newValue
            }
            .onChange(of: appState.selectedChannelIndex) { _, newValue in
                if selectedTabID != -1,
                   newValue != selectedTabID,
                   appState.channels.contains(where: { $0.id == newValue }) {
                    selectedTabID = newValue
                }
            }
        }
    }
}
