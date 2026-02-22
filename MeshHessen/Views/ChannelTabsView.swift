import SwiftUI

/// "Messages" tab — per-channel tab strip with ChannelChatView per channel.
struct ChannelTabsView: View {
    @Environment(\.appState) private var appState

    var body: some View {
        if appState.channels.isEmpty {
            ContentUnavailableView(
                "No Channels",
                systemImage: "antenna.radiowaves.left.and.right",
                description: Text("Connect to a node to load channels.")
            )
        } else {
            TabView(selection: Binding(
                get: { appState.selectedChannelIndex },
                set: { appState.selectedChannelIndex = $0 }
            )) {
                ForEach(appState.channels) { channel in
                    ChannelChatView(channelIndex: channel.id)
                        .tabItem {
                            Label {
                                let unread = (appState.channelMessages[channel.id] ?? []).count
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
