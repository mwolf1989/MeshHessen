import AppKit
import SwiftUI

/// "Download firmware for offline use": fetches one release's artifacts for any number of device types
/// into the firmware cache, so nodes can be updated later without internet (ESP32 → OTA `.bin`;
/// nRF52 → `-ota.zip` + `.uf2`; RP2040 → `.uf2`). Downloads only; nothing is sent to a device.
struct FirmwarePrefetchSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var catalog: FirmwareCatalog?
    @State private var useAlpha = false
    @State private var selectedRelease: FirmwareRelease?
    @State private var filter = ""
    @State private var selectedHardware: Set<DeviceHardware> = []
    @State private var isLoading = false
    @State private var progress: Double?
    @State private var status = ""
    @State private var log: [String] = []
    @State private var downloadTask: Task<Void, Never>?

    private let catalogService = FirmwareCatalogService()
    private let retriever = FirmwareRetriever()
    private let initialCatalog: FirmwareCatalog?
    private let preselect: DeviceHardware?

    init(catalog: FirmwareCatalog?, preselect: DeviceHardware?) {
        initialCatalog = catalog
        self.preselect = preselect
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Download Firmware for Offline Use")
                .font(.title2.bold())
            Text("While online, download the firmware for every device type you want to update later without a network. The assistant finds the files in its cache and marks those releases as available offline.")
                .foregroundStyle(.secondary)

            Picker("Channel", selection: $useAlpha) {
                Text("Stable").tag(false)
                Text("Alpha / pre-release").tag(true)
            }
            .pickerStyle(.segmented)

            Picker("Release", selection: $selectedRelease) {
                ForEach(releases, id: \.id) { release in
                    Text(release.title).tag(Optional(release))
                }
            }

            TextField("Filter device types", text: $filter)
                .textFieldStyle(.roundedBorder)

            List(filteredHardware, id: \.self) { hardware in
                Toggle(isOn: Binding(
                    get: { selectedHardware.contains(hardware) },
                    set: { isOn in
                        if isOn { selectedHardware.insert(hardware) } else { selectedHardware.remove(hardware) }
                    }
                )) {
                    Text("\(hardware.displayName)  (\(hardware.effectiveTarget), \(hardware.architecture))")
                }
            }
            .frame(minHeight: 200)

            if let progress {
                ProgressView(value: progress)
            }
            if !status.isEmpty {
                Text(status).font(.callout)
            }
            if !log.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(log.enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(.caption, design: .monospaced))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 110)
            }

            HStack {
                Button("Show Firmware Folder") {
                    let folder = catalogService.cacheDirectory
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    NSWorkspace.shared.activateFileViewerSelecting([folder])
                }
                Spacer()
                Button("Download") { startDownload() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(downloadTask != nil || selectedRelease == nil || selectedHardware.isEmpty)
                Button(downloadTask == nil ? "Close" : "Cancel") {
                    if let downloadTask {
                        downloadTask.cancel()
                    } else {
                        dismiss()
                    }
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, minHeight: 620)
        .task { await loadCatalog() }
        .onChange(of: useAlpha) { _, _ in selectedRelease = releases.first }
        .onDisappear { downloadTask?.cancel() }
    }

    private var releases: [FirmwareRelease] {
        (useAlpha ? catalog?.alpha : catalog?.stable) ?? []
    }

    private var candidateHardware: [DeviceHardware] {
        (catalog?.hardware ?? [])
            .filter { !FirmwareWizardLogic.prefetchKinds(for: $0).isEmpty }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var filteredHardware: [DeviceHardware] {
        let query = filter.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return candidateHardware }
        return candidateHardware.filter { hardware in
            selectedHardware.contains(hardware)
                || hardware.displayName.localizedCaseInsensitiveContains(query)
                || hardware.effectiveTarget.localizedCaseInsensitiveContains(query)
        }
    }

    private func loadCatalog() async {
        if let initialCatalog, !initialCatalog.isEmpty {
            catalog = initialCatalog
        } else {
            isLoading = true
            status = String(localized: "Loading firmware catalog…")
            catalog = await catalogService.load()
            isLoading = false
        }
        guard let catalog, !catalog.isEmpty else {
            status = String(localized: "Device catalog not available — downloading in advance needs an internet connection.")
            return
        }
        status = ""
        selectedRelease = releases.first
        if let preselect, let match = catalog.hardware.first(where: {
            $0.hwModel == preselect.hwModel
                && $0.platformioTarget.caseInsensitiveCompare(preselect.platformioTarget) == .orderedSame
        }) {
            selectedHardware.insert(match)
        }
    }

    private func startDownload() {
        guard let release = selectedRelease else { return }
        let jobs = selectedHardware
            .sorted { $0.displayName < $1.displayName }
            .flatMap { hardware in FirmwareWizardLogic.prefetchKinds(for: hardware).map { (hardware, $0) } }
        guard !jobs.isEmpty else { return }
        log = []
        progress = 0
        downloadTask = Task {
            var loaded = 0
            var missing = 0
            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                let (hardware, kind) = job
                status = String(localized: "Downloading \(hardware.displayName) – \(kind.fileSuffix) (\(release.version))…")
                do {
                    let artifact = try await retriever.download(release: release, hardware: hardware, kind: kind)
                    loaded += 1
                    log.append("✓ \(artifact.fileName) (\(artifact.size / 1024) KB)")
                } catch is CancellationError {
                    break
                } catch {
                    missing += 1
                    log.append("✗ \(hardware.effectiveTarget) \(kind.fileSuffix): \(error.localizedDescription)")
                }
                progress = Double(index + 1) / Double(jobs.count)
            }
            status = Task.isCancelled
                ? String(localized: "Cancelled.")
                : String(localized: "Finished: \(loaded) file(s) downloaded, \(missing) not available.")
            downloadTask = nil
        }
    }
}
