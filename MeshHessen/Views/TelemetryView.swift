import SwiftUI

/// Statistics overview for a single node, showing signal, power, airtime,
/// and routing metrics split by day and night.
struct TelemetryView: View {
    let nodeId: UInt32
    let nodeName: String

    @State private var selectedDays: Int = 30
    @State private var signalStats = SignalStats()
    @State private var powerStats = PowerStats()
    @State private var airtimeStats = AirtimeStats()
    @State private var routingStats = RoutingStats()
    @State private var showChart = false

    private let dayOptions = [7, 30, 90, 0]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Time range picker
                HStack {
                    Text("Time Range:")
                        .font(.headline)
                    Picker("", selection: $selectedDays) {
                        Text("7 Days").tag(7)
                        Text("30 Days").tag(30)
                        Text("90 Days").tag(90)
                        Text("All").tag(0)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)

                    Spacer()

                    Button {
                        showChart = true
                    } label: {
                        Label("Charts", systemImage: "chart.xyaxis.line")
                    }
                }

                // Signal Section
                GroupBox("Signal (SNR / RSSI)") {
                    statsGrid {
                        statRow("Median SNR", day: fmt(signalStats.daySnrMedian, "dB"), night: fmt(signalStats.nightSnrMedian, "dB"))
                        statRow("Median RSSI", day: fmt(signalStats.dayRssiMedian, "dBm"), night: fmt(signalStats.nightRssiMedian, "dBm"))
                        statRow("SNR Range", value: "\(fmt(signalStats.snrMin, "")) … \(fmt(signalStats.snrMax, "")) dB")
                        statRow("RSSI Range", value: "\(fmt(signalStats.rssiMin, "")) … \(fmt(signalStats.rssiMax, "")) dBm")
                        statRow("SNR Variance", value: fmt(signalStats.snrVariance, ""))
                        statRow("Packets", value: "\(signalStats.packetCount)")
                    }
                }

                // Power Section
                GroupBox("Power (Battery / Voltage)") {
                    statsGrid {
                        statRow("Avg Battery", day: fmt(powerStats.dayBatteryAvg, "%"), night: fmt(powerStats.nightBatteryAvg, "%"))
                        statRow("Avg Voltage", day: fmt(powerStats.dayVoltageAvg, "V"), night: fmt(powerStats.nightVoltageAvg, "V"))
                        statRow("Night Battery Drop", value: fmt(powerStats.nightBatteryDrop, "%"))
                        statRow("Voltage Range", value: "\(fmt(powerStats.voltageMin, "")) … \(fmt(powerStats.voltageMax, "")) V")
                        statRow("Last Uptime", value: formatUptime(powerStats.lastUptime))
                    }
                }

                // Airtime Section
                GroupBox("Airtime (Channel Utilization)") {
                    statsGrid {
                        statRow("Avg Channel Util", day: fmt(airtimeStats.dayChannelUtilAvg, "%"), night: fmt(airtimeStats.nightChannelUtilAvg, "%"))
                        statRow("Avg Air TX Util", day: fmt(airtimeStats.dayAirTxUtilAvg, "%"), night: fmt(airtimeStats.nightAirTxUtilAvg, "%"))
                        statRow("Max Channel Util", value: fmt(airtimeStats.channelUtilMax, "%"))
                        statRow("Max Air TX Util", value: fmt(airtimeStats.airTxUtilMax, "%"))
                    }
                }

                // Routing Section
                GroupBox("Routing (Hops / ACK)") {
                    statsGrid {
                        statRow("Avg Hops", value: fmt(routingStats.avgHops, ""))
                        statRow("Hop Range", value: "\(routingStats.minHops) … \(routingStats.maxHops)")
                        statRow("ACK Rate", value: "\(Int(routingStats.ackSuccessRate * 100))% (\(routingStats.ackReceived)/\(routingStats.ackRequested))")
                        statRow("Unique Neighbors", value: "\(routingStats.uniqueNeighbors)")
                    }

                    if !routingStats.hopDistribution.isEmpty {
                        Text("Hop Distribution")
                            .font(.subheadline).bold()
                            .padding(.top, 4)
                        HStack(spacing: 8) {
                            ForEach(routingStats.hopDistribution.keys.sorted(), id: \.self) { hop in
                                VStack {
                                    Text("\(routingStats.hopDistribution[hop] ?? 0)")
                                        .font(.caption)
                                    Rectangle()
                                        .fill(Color.accentColor.opacity(0.7))
                                        .frame(width: 24, height: CGFloat(routingStats.hopDistribution[hop] ?? 0) * 3)
                                    Text("\(hop)")
                                        .font(.caption2)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 400)
        .navigationTitle("Telemetry — \(nodeName)")
        .onAppear { loadStats() }
        .onChange(of: selectedDays) { loadStats() }
        .sheet(isPresented: $showChart) {
            TelemetryChartView(nodeId: nodeId, nodeName: nodeName, days: effectiveDays)
        }
    }

    private var effectiveDays: Int {
        selectedDays == 0 ? 3650 : selectedDays  // "All" = 10 years
    }

    private func loadStats() {
        let days = effectiveDays
        Task.detached {
            let db = TelemetryDatabaseService.shared
            let signal = db.getSignalStats(nodeId: nodeId, days: days)
            let power = db.getPowerStats(nodeId: nodeId, days: days)
            let airtime = db.getAirtimeStats(nodeId: nodeId, days: days)
            let routing = db.getRoutingStats(nodeId: nodeId, days: days)
            await MainActor.run {
                signalStats = signal
                powerStats = power
                airtimeStats = airtime
                routingStats = routing
            }
        }
    }

    // MARK: - Formatting Helpers

    private func fmt(_ value: Double, _ unit: String) -> String {
        if value == 0 && unit.isEmpty { return "-" }
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
        return unit.isEmpty ? formatted : "\(formatted) \(unit)"
    }

    private func formatUptime(_ seconds: Int) -> String {
        guard seconds > 0 else { return "-" }
        let h = seconds / 3600
        let m = (seconds % 3600) / 60
        if h > 24 {
            return "\(h / 24)d \(h % 24)h"
        }
        return "\(h)h \(m)m"
    }

    // MARK: - Grid Helpers

    @ViewBuilder
    private func statsGrid<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            GridRow {
                Text("").frame(width: 140, alignment: .leading)
                Text("Day").font(.caption).bold().frame(width: 80, alignment: .trailing)
                Text("Night").font(.caption).bold().frame(width: 80, alignment: .trailing)
            }
            content()
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, day: String, night: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(day).font(.system(.caption, design: .monospaced)).frame(width: 80, alignment: .trailing)
            Text(night).font(.system(.caption, design: .monospaced)).frame(width: 80, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func statRow(_ label: String, value: String) -> some View {
        GridRow {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.caption, design: .monospaced)).frame(width: 80, alignment: .trailing)
            Text("").frame(width: 80)
        }
    }
}
