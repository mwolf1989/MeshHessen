import AppKit
import SwiftUI

/// Shared delivery state label used in both channel and DM message bubbles.
struct DeliveryStateLabel: View {
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

/// Emoji picker popover — 4×8 grid of 32 emojis
struct EmojiPickerView: View {
    let onSelect: (String) -> Void

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<EmojiReaction.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(0..<EmojiReaction.columns, id: \.self) { col in
                        let idx = row * EmojiReaction.columns + col
                        if idx < EmojiReaction.allEmojis.count {
                            let emoji = EmojiReaction.allEmojis[idx]
                            Button(emoji) { onSelect(emoji) }
                                .buttonStyle(.plain)
                                .font(.title3)
                                .frame(width: 28, height: 28)
                                .contentShape(Rectangle())
                        }
                    }
                }
            }
        }
        .padding(8)
    }
}

/// Shows reaction pills below a message bubble
struct ReactionPillsView: View {
    let reactions: [String: [UInt32]]

    var body: some View {
        if !reactions.isEmpty {
            HStack(spacing: 4) {
                ForEach(reactions.sorted(by: { $0.key < $1.key }), id: \.key) { emoji, senders in
                    HStack(spacing: 2) {
                        Text(emoji).font(.caption)
                        if senders.count > 1 {
                            Text("\(senders.count)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
                }
            }
        }
    }
}

/// Compact context shown while composing a reply.
struct ReplyComposerBanner: View {
    let message: MessageItem
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrowshape.turn.up.left.fill")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 1) {
                Text("Antwort an \(message.from)")
                    .font(.caption)
                    .fontWeight(.semibold)
                Text(message.message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Button(action: onCancel) {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Antwort abbrechen")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

/// A quoted message preview displayed inside a reply bubble.
private struct ReplyContextView: View {
    let target: MessageItem?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Rectangle()
                .fill(Color.accentColor.opacity(0.7))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 1) {
                Text(target?.from ?? String(localized: "Ursprüngliche Nachricht"))
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Text(target?.message ?? String(localized: "Nicht mehr verfügbar"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .combine)
    }
}

/// Unified message bubble used in both channel chat and DM conversations.
struct MessageBubbleView: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.openWindow) private var openWindow

    let message: MessageItem
    let isMine: Bool
    var protocolReady: Bool = true
    var showColorDot: Bool = false
    var showMqttIndicator: Bool = false
    var replyTarget: MessageItem?
    var onReply: (() -> Void)?
    var onReaction: ((String) -> Void)?
    var onRetry: (() -> Void)?

    @State private var pendingURL: URL?
    @State private var showLinkConfirmation = false
    @State private var showEmojiPicker = false
    @State private var showNodeInfo: NodeInfo?
    @State private var showTraceroute: NodeInfo?
    @State private var showTelemetry: NodeInfo?
    @State private var showNoteEditor = false
    @State private var noteDraft = ""

    var body: some View {
        VStack(alignment: isMine ? .trailing : .leading, spacing: 2) {
            // Header: sender name, optional color dot, optional MQTT indicator, timestamp
            HStack(spacing: 6) {
                if !isMine {
                    if showColorDot,
                       !message.senderColorHex.isEmpty,
                       let color = Color(hex: message.senderColorHex) {
                        Circle().fill(color).frame(width: 8, height: 8)
                    }
                    Text(message.from)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                if showMqttIndicator && message.isViaMqtt {
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

            // Reply context and message body share one bubble.
            VStack(alignment: .leading, spacing: 5) {
                if message.replyToPacketId != nil {
                    ReplyContextView(target: replyTarget)
                }

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
                            .help("Verschlüsselt — Kanalschlüssel (PSK) nicht konfiguriert")
                        Text(encryptedMessageText)
                            .italic()
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if let attributed = Self.detectLinks(in: visibleMessageText) {
                        Text(attributed)
                            .textSelection(.enabled)
                    } else {
                        Text(visibleMessageText)
                            .textSelection(.enabled)
                    }
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
            .contextMenu {
                Button {
                    copyMessageText()
                } label: {
                    Label("Nachricht kopieren", systemImage: "doc.on.doc")
                }

                if message.routablePacketId != nil {
                    if onReply != nil || onReaction != nil {
                        Divider()
                    }
                    if let onReply {
                        Button {
                            onReply()
                        } label: {
                            Label("Antworten", systemImage: "arrowshape.turn.up.left")
                        }
                    }

                    if let onReaction {
                        if onReply != nil {
                            Divider()
                        }
                        // Quick reactions
                        ForEach(["👍", "❤️", "😂", "👎"], id: \.self) { emoji in
                            Button(emoji) { onReaction(emoji) }
                        }
                        Divider()
                        Button("More Reactions…") { showEmojiPicker = true }
                    }
                }

                if let senderNode {
                    Divider()
                    if senderNode.id != appState.myNodeInfo?.nodeId {
                        Button {
                            appState.ensureDMConversation(for: senderNode.id)
                            appState.dmTargetNodeId = senderNode.id
                            openWindow(id: "dm")
                        } label: {
                            Label("Send Direct Message", systemImage: "bubble.left")
                        }
                    }
                    Button { showNodeInfo = senderNode } label: {
                        Label("Show Node Info", systemImage: "info.circle")
                    }
                    Button {
                        coordinator.router.navigateToNodeOnMap(nodeNum: senderNode.id)
                    } label: {
                        Label("Show on Map", systemImage: "map")
                    }
                    .disabled(senderNode.latitude == nil || senderNode.longitude == nil)
                    Button(
                        senderNode.isFavorite
                            ? String(localized: "Remove Favorite")
                            : String(localized: "Add Favorite")
                    ) {
                        Task {
                            _ = await coordinator.protocol_.setFavorite(
                                !senderNode.isFavorite,
                                nodeId: senderNode.id
                            )
                        }
                    }
                    Button(
                        senderNode.isPinned
                            ? String(localized: "Unpin")
                            : String(localized: "Pin")
                    ) {
                        senderNode.isPinned.toggle()
                        coordinator.coreDataStore.updateNodePinState(
                            nodeId: senderNode.id,
                            isPinned: senderNode.isPinned
                        )
                    }
                    Button("Edit Note…") {
                        noteDraft = senderNode.note
                        showNoteEditor = true
                    }
                    Menu("Set Color") {
                        ForEach(nodeColorPresets, id: \.hex) { preset in
                            Button(preset.name) {
                                setColor(preset.hex, for: senderNode)
                            }
                        }
                        Divider()
                        Button("Clear Color") { setColor("", for: senderNode) }
                    }
                    Divider()
                    Button("Toggle Position Track") {
                        appState.mapPathToggleNodeId = senderNode.id
                        coordinator.router.navigateToNodeOnMap(nodeNum: senderNode.id)
                    }
                    Button("Traceroute…") { showTraceroute = senderNode }
                        .disabled(senderNode.id == appState.myNodeInfo?.nodeId)
                    Button("Telemetry…") { showTelemetry = senderNode }
                }
            }
            .popover(isPresented: $showEmojiPicker) {
                EmojiPickerView { emoji in
                    showEmojiPicker = false
                    onReaction?(emoji)
                }
            }

            // Reaction pills
            ReactionPillsView(reactions: message.reactionsByEmoji)

            if let receptionSummary {
                Label(receptionSummary.text, systemImage: receptionSummary.symbol)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(receptionSummary.color)
                    .help(receptionSummary.help)
                    .accessibilityLabel("Message reception")
                    .accessibilityValue(receptionSummary.text)
            }

            if isMine {
                HStack(spacing: 6) {
                    DeliveryStateLabel(state: message.deliveryState)
                    if case .failed = message.deliveryState, let onRetry {
                        Button("Erneut senden", action: onRetry)
                            .buttonStyle(.link)
                            .font(.caption2)
                            .accessibilityLabel("Nachricht erneut senden")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: isMine ? .trailing : .leading)
        .environment(\.openURL, OpenURLAction { url in
            pendingURL = url
            showLinkConfirmation = true
            return .handled
        })
        .alert("Link öffnen?", isPresented: $showLinkConfirmation, presenting: pendingURL) { url in
            Button("Öffnen") {
                NSWorkspace.shared.open(url)
            }
            Button("Link kopieren") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Button("Abbrechen", role: .cancel) {}
        } message: { url in
            Text(url.absoluteString)
        }
        .alert("Node Note", isPresented: $showNoteEditor) {
            TextField("Note", text: $noteDraft)
            Button("Save") { saveNote() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Store a local note for this message sender.")
        }
        .sheet(item: $showNodeInfo) { node in
            NodeInfoSheet(node: node)
        }
        .sheet(item: $showTraceroute) { node in
            TracerouteSheet(targetNodeId: node.id, targetName: node.name)
        }
        .sheet(item: $showTelemetry) { node in
            TelemetryView(nodeId: node.id, nodeName: node.name)
        }
    }

    private var senderNode: NodeInfo? {
        guard message.fromId != 0 else { return nil }
        return appState.node(forId: message.fromId)
    }

    private var visibleMessageText: String {
        guard message.hasAlertBell else { return message.message }
        var value = message.message.replacingOccurrences(of: "\u{0007}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix("🔔") {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? String(localized: "Emergency alert") : value
    }

    private var receptionSummary: (text: String, symbol: String, color: Color, help: String)? {
        guard !message.isViaMqtt, let hopCount = message.hopCount else { return nil }
        if hopCount > 0 {
            let text = localizedHopCount(hopCount)
            return (text, "point.3.connected.trianglepath.dotted", .secondary,
                    String(localized: "Relayed message; end-to-end RSSI/SNR is not available"))
        }

        var parts: [String] = []
        if let snr = message.receivedSnr { parts.append(String(format: "SNR %.1f dB", snr)) }
        if let rssi = message.receivedRssi { parts.append("RSSI \(rssi) dBm") }
        guard !parts.isEmpty else { return nil }
        let color: Color
        if let snr = message.receivedSnr {
            color = snr >= 0 ? .green : (snr >= -10 ? .orange : .red)
        } else if let rssi = message.receivedRssi {
            color = rssi >= -90 ? .green : (rssi >= -110 ? .orange : .red)
        } else {
            color = .secondary
        }
        return (parts.joined(separator: " · "), "antenna.radiowaves.left.and.right", color,
                String(localized: "Direct RF reception quality"))
    }

    private var encryptedMessageText: String {
        if !protocolReady {
            return String(localized: "Kanal wird noch geladen…")
        }
        if message.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Verschlüsselte Nachricht – kein passender Schlüssel verfügbar")
        }
        return message.message
    }

    private func copyMessageText() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(visibleMessageText, forType: .string)
    }

    private func setColor(_ colorHex: String, for node: NodeInfo) {
        node.colorHex = colorHex
        SettingsService.shared.setColorHex(colorHex, for: node.id)
        coordinator.coreDataStore.updateNodeCustomization(
            nodeId: node.id,
            colorHex: colorHex,
            note: node.note
        )
    }

    private func saveNote() {
        guard let node = senderNode else { return }
        let note = noteDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        node.note = note
        SettingsService.shared.setNote(note, for: node.id)
        coordinator.coreDataStore.updateNodeCustomization(
            nodeId: node.id,
            colorHex: node.colorHex,
            note: note
        )
    }

    /// Detect URLs in the given string and return an AttributedString with `.link` attributes.
    /// Returns `nil` if no links are found.
    private static let linkDetector: NSDataDetector? = {
        try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
    }()

    private static func detectLinks(in text: String) -> AttributedString? {
        guard let detector = linkDetector else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        let matches = detector.matches(in: text, range: range)
        guard !matches.isEmpty else { return nil }

        var attributed = AttributedString(text)
        for match in matches {
            guard let matchRange = Range(match.range, in: text),
                  let url = match.url else { continue }
            let attrRange = AttributedString.Index(matchRange.lowerBound, within: attributed)
                .flatMap { lower in
                    AttributedString.Index(matchRange.upperBound, within: attributed)
                        .map { upper in lower..<upper }
                }
            guard let attrRange else { continue }
            attributed[attrRange].link = url
        }
        return attributed
    }
}
