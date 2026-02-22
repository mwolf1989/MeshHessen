import SwiftUI

/// Per-channel chat message list with send bar and SOS button.
struct ChannelChatView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    let channelIndex: Int
    @State private var messageText = ""
    @State private var isSending = false
    @FocusState private var inputFocused: Bool

    private var messages: [MessageItem] {
        appState.channelMessages[channelIndex] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                                .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: messages.count) { _, _ in
                    if let last = messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button {
                    AppLogger.shared.log("[UI] User triggered SOS alert on channel \(channelIndex)", debug: true)
                    Task { await coordinator.sendSOSAlert(customText: nil) }
                } label: {
                    Text("SOS")
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.red)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Send SOS broadcast on this channel")

                TextField("Message…", text: $messageText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...4)
                    .focused($inputFocused)

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
        .onAppear {
            appState.clearChannelUnread(channelIndex)
            appState.selectedChannelIndex = channelIndex
        }
        .onChange(of: channelIndex) { _, new in
            appState.clearChannelUnread(new)
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        isSending = true
        AppLogger.shared.log("[UI] Sending message to channel \(channelIndex): \(text.prefix(50))\(text.count > 50 ? "..." : "")", debug: SettingsService.shared.debugMessages)
        Task {
            await coordinator.sendMessage(text, toChannelIndex: channelIndex)
            isSending = false
        }
    }
}

private struct MessageBubble: View {
    let message: MessageItem
    @Environment(\.appState) private var appState

    private var isMine: Bool {
        guard let me = appState.myNodeInfo else { return false }
        return message.fromId == me.nodeId
    }

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            // Header: sender name, MQTT indicator, timestamp
            HStack(spacing: 6) {
                if !isMine {
                    if !message.senderColorHex.isEmpty,
                       let color = Color(hex: message.senderColorHex) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(message.from)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                if message.isViaMqtt {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .help("Via MQTT")
                }
                Spacer(minLength: 0)
                Text(message.time)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            // Message body
            HStack(spacing: 4) {
                if message.hasAlertBell {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                }
                if message.isEncrypted {
                    Image(systemName: "lock.fill")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    Text(message.message)
                        .italic()
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text(message.message)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                message.isEncrypted
                    ? Color.secondary.opacity(0.08)
                    : (isMine ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))

            if isMine {
                DeliveryStateLabel(state: message.deliveryState)
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
    }
}

private struct DeliveryStateLabel: View {
    let state: MessageDeliveryState

    var body: some View {
        switch state {
        case .none:
            EmptyView()
        case .pending:
            Text("Warte auf ACK…")
                .font(.caption2)
                .foregroundStyle(.orange)
        case .acknowledged:
            Text("Zugestellt")
                .font(.caption2)
                .foregroundStyle(.green)
        case .failed(let reason):
            Text(reason)
                .font(.caption2)
                .foregroundStyle(.red)
        }
    }
}
