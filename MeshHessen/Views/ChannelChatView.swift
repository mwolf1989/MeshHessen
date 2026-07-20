import SwiftUI

/// Per-channel chat message list with send bar and SOS button.
struct ChannelChatView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    let channelIndex: Int
    @State private var messageText = ""
    @State private var isSending = false
    @State private var showDeleteConfirmation = false
    @State private var showSOSConfirmation = false
    @State private var replyingTo: MessageItem?
    @FocusState private var inputFocused: Bool

    private var messages: [MessageItem] {
        appState.channelMessages[channelIndex] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                Button {
                    showDeleteConfirmation = true
                } label: {
                    Label("Nachrichten löschen", systemImage: "trash")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(messages.isEmpty)
                .help("Alle Nachrichten in diesem Kanal löschen")
                .padding(.trailing, 12)
                .padding(.top, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isMine: msg.fromId == appState.myNodeInfo?.nodeId,
                                protocolReady: appState.protocolReady,
                                showColorDot: true,
                                showMqttIndicator: true,
                                replyTarget: replyTarget(for: msg),
                                onReply: msg.routablePacketId == nil ? nil : {
                                    beginReply(to: msg)
                                },
                                onReaction: reactionHandler(for: msg)
                            )
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

            VStack(spacing: 6) {
                if let replyingTo {
                    ReplyComposerBanner(message: replyingTo) {
                        self.replyingTo = nil
                        inputFocused = true
                    }
                }

                HStack(spacing: 8) {
                    Button {
                        showSOSConfirmation = true
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
                        .frame(maxWidth: .infinity)
                        .focused($inputFocused)

                    Button(action: sendMessage) {
                        Image(systemName: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isSending)
                    .keyboardShortcut(.return, modifiers: .command)
                }
            }
            .padding(10)
        }
        .onAppear {
            appState.clearChannelUnread(channelIndex)
            appState.selectedChannelIndex = channelIndex
        }
        .onChange(of: channelIndex) { _, new in
            replyingTo = nil
            appState.clearChannelUnread(new)
        }
        .alert("Nachrichten löschen?", isPresented: $showDeleteConfirmation) {
            Button("Löschen", role: .destructive) {
                replyingTo = nil
                coordinator.clearChannelMessages(channelIndex)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Nachrichten in diesem Kanal werden unwiderruflich gelöscht.")
        }
        .confirmationDialog("SOS-Alarm senden?", isPresented: $showSOSConfirmation) {
            Button("SOS senden", role: .destructive) {
                AppLogger.shared.log("[UI] User triggered SOS alert on channel \(channelIndex)", debug: true)
                Task { await coordinator.sendSOSAlert(customText: nil) }
            }
            Button("Abbrechen", role: .cancel) {}
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let replyToPacketId = replyingTo?.packetId
        messageText = ""
        replyingTo = nil
        isSending = true
        AppLogger.shared.log("[UI] Sending message to channel \(channelIndex): \(text.prefix(50))\(text.count > 50 ? "..." : "")", debug: SettingsService.shared.debugMessages)
        Task {
            await coordinator.sendMessage(
                text,
                toChannelIndex: channelIndex,
                replyToPacketId: replyToPacketId
            )
            isSending = false
        }
    }

    private func beginReply(to message: MessageItem) {
        guard message.routablePacketId != nil else { return }
        replyingTo = message
        inputFocused = true
    }

    private func replyTarget(for message: MessageItem) -> MessageItem? {
        guard let targetPacketId = message.replyToPacketId else { return nil }
        return messages.first { $0.packetId == targetPacketId }
    }

    private func reactionHandler(for message: MessageItem) -> ((String) -> Void)? {
        guard let packetId = message.routablePacketId else { return nil }
        return { emoji in
            Task {
                await coordinator.sendEmojiReaction(
                    emoji,
                    toPacketId: packetId,
                    toNodeId: 0xFFFFFFFF,
                    channelIndex: channelIndex
                )
            }
        }
    }
}
