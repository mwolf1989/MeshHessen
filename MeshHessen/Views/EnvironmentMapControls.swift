import SwiftUI

/// Map toolbar popover for the environment overlay: master toggle, value boxes, heatmap
/// metric, node exclusion list and legend.
struct EnvironmentMapControls: View {
    @Bindable var settings: SettingsService
    let overlay: EnvironmentOverlay?

    /// Metrics with data, plus the current selection so the picker never loses it.
    private var selectableMetrics: [EnvironmentMetric] {
        let available = overlay?.availableMetricKeys ?? []
        return EnvironmentMetricInfo.all.filter {
            available.contains($0.key) || $0.key == settings.environmentMetricKey
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Show environment data on the map", isOn: $settings.showEnvironmentData)
            } footer: {
                Text("Shows sensor readings that nodes report (temperature, humidity, pressure and more).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.showEnvironmentData {
                Section("Value Boxes") {
                    Picker("Value boxes at nodes", selection: $settings.environmentBoxMode) {
                        ForEach(EnvironmentBoxMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                }

                Section("Heatmap") {
                    Toggle("Heatmap overlay", isOn: $settings.environmentShowHeatmap)
                    Picker("Heatmap metric", selection: $settings.environmentMetricKey) {
                        ForEach(selectableMetrics) { metric in
                            Text(metric.displayName).tag(metric.key)
                        }
                    }
                    if settings.environmentShowHeatmap, let legend = overlay?.surface?.legend {
                        EnvironmentLegendView(legend: legend)
                    } else if settings.environmentShowHeatmap, overlay != nil {
                        Text("No data for this metric in the last 48 hours.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    EnvironmentNodeList(settings: settings, nodes: overlay?.sensorNodes ?? [])
                } header: {
                    Text("Include Nodes")
                } footer: {
                    Text("Deselect a node that measures nonsense – it disappears from boxes and heatmap.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .frame(width: 340)
        .frame(maxHeight: 620)
    }
}

private struct EnvironmentNodeList: View {
    @Bindable var settings: SettingsService
    let nodes: [EnvironmentNodePosition]

    var body: some View {
        if nodes.isEmpty {
            Text("No nodes with environment data received yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(nodes, id: \.nodeId) { node in
                Toggle(isOn: inclusionBinding(for: node.nodeId)) {
                    Text(node.title)
                        .lineLimit(1)
                }
            }
        }
    }

    private func inclusionBinding(for nodeId: UInt32) -> Binding<Bool> {
        Binding(
            get: { !settings.environmentExcludedNodeIds.contains(nodeId) },
            set: { included in
                var excluded = settings.environmentExcludedNodeIds
                if included { excluded.remove(nodeId) } else { excluded.insert(nodeId) }
                settings.environmentExcludedNodeIds = excluded
            }
        )
    }
}

/// Banded colour scale of the heatmap metric, warmest band on top.
struct EnvironmentLegendView: View {
    let legend: EnvironmentLegend

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(legend.unit.isEmpty ? legend.title : "\(legend.title) (\(legend.unit))")
                .font(.caption.bold())
            ForEach(Array(legend.bands.enumerated().reversed()), id: \.offset) { _, band in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(
                            red: Double(band.rgb.r) / 255,
                            green: Double(band.rgb.g) / 255,
                            blue: Double(band.rgb.b) / 255
                        ))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(.black.opacity(0.3), lineWidth: 1))
                        .frame(width: 15, height: 11)
                    Text(verbatim: "\(Self.format(band.lo))–\(Self.format(band.hi))")
                        .font(.caption2.monospacedDigit())
                }
            }
            Text("Interpolated between sensors")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private static func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)).grouping(.never))
    }
}
