import SwiftUI

/// "Messages" tab — per-channel tab strip with ChannelChatView per channel.
struct ChannelTabsView: View {
    @Environment(\.appState) private var appState

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
            TabView(selection: Binding(
                get: {
                    if appState.channels.contains(where: { $0.id == appState.selectedChannelIndex }) {
                        return appState.selectedChannelIndex
                    }
                    return appState.channels.first?.id ?? 0
                },
                set: { newValue in
                    guard appState.channels.contains(where: { $0.id == newValue }) else { return }
                    appState.selectedChannelIndex = newValue
                }
            )) {
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
        }
    }
}
