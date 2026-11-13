import SwiftUI
import UniformTypeIdentifiers

/// Tools section: back up the local node's complete configuration to JSON
/// (Windows-compatible layout) and restore it, keeping security keys when the
/// backup belongs to another node.
struct ConfigBackupSection: View {
    @Environment(\.appState) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    @State private var isWorking = false
    @State private var progress: AdminConfigurationLoadProgress?
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    @State private var exportDocument: ConfigBackupDocument?
    @State private var exportFileName = ""
    @State private var showExporter = false

    @State private var showImporter = false
    @State private var pendingRestore: PendingRestore?

    private var isConnected: Bool { appState.connectionState.isConnected }

    var body: some View {
        Section {
            Button {
                Task { await createBackup() }
            } label: {
                Label("Create Backup…", systemImage: "square.and.arrow.down")
            }
            .disabled(!isConnected || isWorking)
            .fileExporter(
                isPresented: $showExporter,
                document: exportDocument,
                contentType: .json,
                defaultFilename: exportFileName
            ) { result in
                switch result {
                case .success:
                    statusMessage = String(localized: "Backup saved.")
                case .failure(let error):
                    errorMessage = error.localizedDescription
                }
                exportDocument = nil
            }

            Button {
                showImporter = true
            } label: {
                Label("Restore Backup…", systemImage: "square.and.arrow.up")
            }
            .disabled(!isConnected || isWorking)
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [.json],
                allowsMultipleSelection: false,
                onCompletion: openBackup
            )

            if isWorking {
                if let progress {
                    ProgressView(value: progress.fractionCompleted) {
                        Text(progress.currentStep)
                            .font(.callout)
                    }
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            } else if let statusMessage {
                Text(statusMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Text("The file contains channel keys and, for this node, its private key. Store it safely.")
                .font(.callout)
                .foregroundStyle(.secondary)
        } header: {
            Text("Configuration Backup")
        } footer: {
            if !isConnected {
                Text("Connect to a node to create or restore a backup.")
            }
        }
        .sheet(item: $pendingRestore) { pending in
            ConfigRestoreConfirmationSheet(summary: pending.summary) {
                pendingRestore = nil
                Task { await restore(pending.file) }
            } onCancel: {
                pendingRestore = nil
            }
        }
        .alert("Configuration Backup", isPresented: errorPresented) {
            Button("OK", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? String(localized: "Unknown error"))
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }

    // MARK: - Actions

    private func createBackup() async {
        isWorking = true
        progress = nil
        statusMessage = nil
        defer {
            isWorking = false
            progress = nil
        }
        do {
            let file = try await coordinator.exportConfigurationBackup { progress = $0 }
            exportDocument = ConfigBackupDocument(data: try file.jsonData())
            exportFileName = file.defaultFileBaseName()
            showExporter = true
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func openBackup(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
            }
            do {
                let file = try ConfigBackupFile(jsonData: try Data(contentsOf: url))
                let summary = file.summary(
                    connectedNodeId: coordinator.protocol_.currentNodeId,
                    connectedFirmware: coordinator.protocol_.localFirmwareVersion() ?? ""
                )
                pendingRestore = PendingRestore(file: file, summary: summary)
            } catch {
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    private func restore(_ file: ConfigBackupFile) async {
        isWorking = true
        progress = nil
        statusMessage = nil
        defer {
            isWorking = false
            progress = nil
        }
        do {
            let diff = try await coordinator.restoreConfigurationBackup(file) { progress = $0 }
            statusMessage = diff.isEmpty
                ? String(localized: "The device already matches the backup; nothing was written.")
                : String(localized: "\(diff.labels.count) sections written; the device will reboot.")
        } catch is CancellationError {
            return
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct PendingRestore: Identifiable {
    let id = UUID()
    let file: ConfigBackupFile
    let summary: ConfigBackupSummary
}

// MARK: - Confirmation sheet

private struct ConfigRestoreConfirmationSheet: View {
    let summary: ConfigBackupSummary
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Restore Configuration?")
                .font(.title2.bold())

            Form {
                LabeledContent("Source node") {
                    Text(verbatim: sourceNodeText)
                }
                if let exportedAt = summary.exportedAt {
                    LabeledContent("Created") {
                        Text(exportedAt, format: .dateTime)
                    }
                }
                LabeledContent("Backup firmware") {
                    Text(verbatim: summary.backupFirmware.isEmpty ? "–" : summary.backupFirmware)
                }
                LabeledContent("Device firmware") {
                    Text(verbatim: summary.deviceFirmware.isEmpty ? "–" : summary.deviceFirmware)
                }
                sectionRow("Configuration", summary.configTitles)
                sectionRow("Modules", summary.moduleTitles)
                sectionRow("Channels", summary.channelNames)
            }
            .formStyle(.grouped)

            if summary.securitySkipped {
                Label(
                    "This backup belongs to a different node. Security keys will not be restored.",
                    systemImage: "lock.shield"
                )
                .foregroundStyle(.orange)
            } else if !summary.isSameNode {
                Label("This backup belongs to a different node.", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Text("Settings in the backup replace the device's settings. The device usually reboots afterwards.")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Restore", action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
    }

    private var sourceNodeText: String {
        var text = summary.sourceNodeIdText
        if let longName = summary.ownerLongName, !longName.isEmpty {
            text += " · \(longName)"
        }
        return text
    }

    private func sectionRow(_ title: LocalizedStringKey, _ items: [String]) -> some View {
        LabeledContent(title) {
            Text(verbatim: items.isEmpty ? "–" : items.joined(separator: ", "))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
    }
}
