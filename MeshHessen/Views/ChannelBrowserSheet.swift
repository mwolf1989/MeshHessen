import SwiftUI

/// Sheet for browsing CHANNELS.csv with Bundesland filter + search.
struct ChannelBrowserSheet: View {
    @Environment(AppCoordinator.self) private var coordinator
    @Environment(\.dismiss) private var dismiss

    @State private var channels: [CSVChannel] = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var selectedBundesland = "All"
    @State private var isAdding = false

    private var bundeslaender: [String] {
        let all = Set(channels.map { $0.bundesland }).sorted()
        return ["All"] + all
    }

    private var filtered: [CSVChannel] {
        channels.filter { ch in
            let matchBL = selectedBundesland == "All" || ch.bundesland == selectedBundesland
            let matchSearch = searchText.isEmpty
                || ch.name.localizedCaseInsensitiveContains(searchText)
                || ch.bundesland.localizedCaseInsensitiveContains(searchText)
            return matchBL && matchSearch
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Channel Browser")
                    .font(.title2)
                    .fontWeight(.bold)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding(16)

            Divider()

            HStack(spacing: 8) {
                TextField("Search…", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Bundesland", selection: $selectedBundesland) {
                    ForEach(bundeslaender, id: \.self) { bl in
                        Text(bl).tag(bl)
                    }
                }
                .frame(width: 160)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            if isLoading {
                ProgressView("Loading channels…")
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filtered) {
                    TableColumn("Name") { ch in
                        Text(ch.name).lineLimit(1)
                    }
                    .width(min: 120, ideal: 180)

                    TableColumn("Bundesland") { ch in
                        Text(ch.bundesland)
                            .foregroundStyle(.secondary)
                    }
                    .width(120)

                    TableColumn("PSK") { ch in
                        Text(ch.psk.isEmpty ? "(none)" : "••••")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .width(60)

                    TableColumn("") { ch in
                        Button("Add") {
                            isAdding = true
                            Task {
                                await coordinator.addChannel(
                                    name: ch.name,
                                    pskBase64: ch.psk,
                                    uplinkEnabled: false,
                                    downlinkEnabled: false
                                )
                                isAdding = false
                            }
                        }
                        .buttonStyle(.bordered)
                        .disabled(isAdding)
                    }
                    .width(60)
                }
            }
        }
        .frame(minWidth: 580, minHeight: 440)
        .task { await loadChannels() }
    }

    private func loadChannels() async {
        // Try remote first, fall back to embedded CSV
        if let remote = try? await fetchRemoteChannels() {
            channels = remote
        } else {
            channels = loadBundledChannels()
        }
        isLoading = false
    }

    private func fetchRemoteChannels() async throws -> [CSVChannel] {
        let url = URL(string: "https://raw.githubusercontent.com/SMLunchen/mh_windowsclient/master/CHANNELS.csv")!
        let (data, _) = try await URLSession.shared.data(from: url)
        return parseCSV(String(decoding: data, as: UTF8.self))
    }

    private func loadBundledChannels() -> [CSVChannel] {
        guard let url = Bundle.main.url(forResource: "CHANNELS", withExtension: "csv"),
              let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parseCSV(content)
    }

    private func parseCSV(_ text: String) -> [CSVChannel] {
        let lines = text.components(separatedBy: .newlines)
        // CSV format: Bundesland;Name;PSK;MQTT_enabled;Bemerkung
        return lines.dropFirst().compactMap { line -> CSVChannel? in
            let parts = line.components(separatedBy: ";")
            guard parts.count >= 3 else { return nil }
            let bundesland = parts[0].trimmingCharacters(in: .whitespaces)
            let name = parts[1].trimmingCharacters(in: .whitespaces)
            let psk = parts[2].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            return CSVChannel(name: name, psk: psk, bundesland: bundesland)
        }
    }
}

struct CSVChannel: Identifiable {
    let id = UUID()
    let name: String
    let psk: String
    let bundesland: String
}
