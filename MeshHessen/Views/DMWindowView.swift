import SwiftUI

/// Floating DM window — one tab per active DM conversation.
struct DMWindowView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @State private var selectedNodeId: UInt32?
    @State private var messageText = ""
    @FocusState private var inputFocused: Bool

    private var conversations: [DirectMessageConversation] {
        Array(appState.dmConversations.values).sorted { $0.nodeName < $1.nodeName }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedNodeId) {
                ForEach(conversations) { conv in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(conv.nodeName)
                                    .fontWeight(conv.hasUnread ? .bold : .medium)
                                    .foregroundStyle(conv.hasUnread ? Color.orange : Color.primary)
                                if conv.hasUnread {
                                    Circle()
                                        .fill(Color.orange)
                                        .frame(width: 8, height: 8)
                                }
                            }
                            if let last = conv.messages.last {
                                Text(last.message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                    }
                    .tag(conv.id)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Direct Messages")
        } detail: {
            if let nodeId = selectedNodeId,
               let conv = appState.dmConversations[nodeId] {
                DMConversationView(conversation: conv, coordinator: coordinator)
            } else {                ContentUnavailableView(
                    "No Conversation Selected",
                    systemImage: "message",
                    description: Text("Select a conversation from the sidebar.")
                )
            }
        }
        .onAppear(perform: consumeTargetNode)
        .onChange(of: appState.dmTargetNodeId) { _, _ in consumeTargetNode() }
        .onChange(of: selectedNodeId) { _, newId in
            markConversationRead(newId)
        }
    }

    /// If a target node was set (e.g. from a context menu), select it and clear the flag.
    private func consumeTargetNode() {
        guard let targetId = appState.dmTargetNodeId else { return }
        appState.dmTargetNodeId = nil
        selectedNodeId = targetId
        markConversationRead(targetId)
    }

    /// Clears the unread flag on the selected conversation.
    private func markConversationRead(_ nodeId: UInt32?) {
        guard let nodeId, let conv = appState.dmConversations[nodeId] else { return }
        conv.hasUnread = false
        // Persist unread state to CoreData
        coordinator.coreDataStore.setConversationUnread(partnerNodeId: nodeId, hasUnread: false)
    }
}

private struct DMConversationView: View {
    let conversation: DirectMessageConversation
    let coordinator: AppCoordinator
    @Environment(\.appState) private var appState
    @State private var messageText = ""
    @State private var isSending = false
    @State private var showDeleteConfirmation = false
    @FocusState private var inputFocused: Bool

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
                .disabled(conversation.messages.isEmpty)
                .help("Alle Nachrichten in dieser Konversation löschen")
                .padding(.trailing, 12)
                .padding(.top, 4)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(conversation.messages) { msg in
                            MessageBubbleView(
                                message: msg,
                                isMine: msg.fromId == appState.myNodeInfo?.nodeId
                            )
                            .id(msg.id)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: conversation.messages.count) { _, _ in
                    if let last = conversation.messages.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }

            Divider()

            HStack(spacing: 8) {
                TextField("Message to \(conversation.nodeName)…", text: $messageText, axis: .vertical)
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
            .padding(10)
        }
        .navigationTitle("DM: \(conversation.nodeName)")
        .onAppear {
            conversation.hasUnread = false
            coordinator.coreDataStore.setConversationUnread(partnerNodeId: conversation.id, hasUnread: false)
        }
        .alert("Nachrichten löschen?", isPresented: $showDeleteConfirmation) {
            Button("Löschen", role: .destructive) {
                appState.clearDMMessages(for: conversation.id)
                coordinator.coreDataStore.deleteConversationMessages(partnerNodeId: conversation.id)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Nachrichten in dieser Konversation werden unwiderruflich gelöscht.")
        }
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        messageText = ""
        isSending = true
        Task {
            await coordinator.sendDirectMessage(text, toNodeId: conversation.id)
            isSending = false
        }
    }
}

