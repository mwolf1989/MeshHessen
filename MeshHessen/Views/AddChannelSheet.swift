import SwiftUI

/// Sheet for manually adding a new channel by name + PSK.
struct AddChannelSheet: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var channelName = ""
    @State private var psk = ""
    @State private var uplinkEnabled = false
    @State private var downlinkEnabled = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Channel")
                .font(.title2)
                .fontWeight(.bold)

            Divider()

            Form {
                TextField("Channel Name", text: $channelName)
                TextField("PSK (base64)", text: $psk)
                    .font(.system(.body, design: .monospaced))

                Toggle("Uplink Enabled", isOn: $uplinkEnabled)
                Toggle("Downlink Enabled", isOn: $downlinkEnabled)
            }
            .formStyle(.grouped)

            if let err = errorMessage {
                Text(err)
                    .foregroundStyle(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape, modifiers: [])
                Button("Add Channel") {
                    addChannel()
                }
                .buttonStyle(.borderedProminent)
                .disabled(channelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isAdding)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(20)
        .frame(minWidth: 420, minHeight: 320)
    }

    private func addChannel() {
        let name = channelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        isAdding = true
        errorMessage = nil
        Task {
            await coordinator.addChannel(
                    name: name,
                    pskBase64: psk,
                    uplinkEnabled: uplinkEnabled,
                    downlinkEnabled: downlinkEnabled
                )
            isAdding = false
            dismiss()
        }
    }
}
