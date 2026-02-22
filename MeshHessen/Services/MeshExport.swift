import Foundation
import UniformTypeIdentifiers
import SwiftUI

// MARK: - CSV Document

/// A `FileDocument` wrapping CSV text for export via `.fileExporter`.
struct CsvDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }

    var csvData: String

    init(csvData: String) {
        self.csvData = csvData
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        csvData = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = csvData.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Log Document

/// A `FileDocument` wrapping plain-text log data for export.
struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var logFile: String

    init(logFile: String) {
        self.logFile = logFile
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        logFile = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        guard let data = logFile.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - Export Functions

enum MeshExport {
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Exports node data to CSV.
    static func nodesToCsv(_ nodes: [NodeInfo]) -> String {
        var csv = "NodeID,ShortName,LongName,DisplayName,Latitude,Longitude,Altitude,Battery%,Voltage,SNR,RSSI,Distance_m,LastHeard,ViaMQTT,ChUtil%,AirTx%\n"
        for node in nodes {
            let lat = node.latitude.map { String(format: "%.7f", $0) } ?? ""
            let lon = node.longitude.map { String(format: "%.7f", $0) } ?? ""
            let alt = node.altitude.map { String($0) } ?? ""
            let lastHeard = node.lastHeard > 0
                ? dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(node.lastHeard)))
                : ""

            csv += "\(node.nodeId),\(escapeCsv(node.shortName)),\(escapeCsv(node.longName)),\(escapeCsv(node.name)),"
            csv += "\(lat),\(lon),\(alt),"
            csv += "\(node.batteryLevel),\(String(format: "%.2f", node.voltage)),"
            csv += "\(String(format: "%.1f", node.snrFloat)),\(node.rssiInt),"
            csv += "\(String(format: "%.0f", node.distanceMeters)),\(lastHeard),"
            csv += "\(node.viaMqtt),\(String(format: "%.1f", node.channelUtilization)),"
            csv += "\(String(format: "%.1f", node.airUtilTx))\n"
        }
        return csv
    }

    /// Exports messages to CSV.
    static func messagesToCsv(_ messages: [MessageItem]) -> String {
        var csv = "PacketID,Time,From,FromID,ToID,Message,ChannelIndex,ChannelName,Encrypted,MQTT,AlertBell,DeliveryState\n"
        for msg in messages {
            let packetId = msg.packetId.map { String($0) } ?? ""
            let deliveryState: String = {
                switch msg.deliveryState {
                case .none: return "none"
                case .pending: return "pending"
                case .acknowledged: return "acknowledged"
                case .failed(let reason): return "failed: \(reason)"
                }
            }()

            csv += "\(packetId),\(escapeCsv(msg.time)),\(escapeCsv(msg.from)),\(msg.fromId),\(msg.toId),"
            csv += "\(escapeCsv(msg.message)),\(msg.channelIndex),\(escapeCsv(msg.channelName)),"
            csv += "\(msg.isEncrypted),\(msg.isViaMqtt),\(msg.hasAlertBell),\(escapeCsv(deliveryState))\n"
        }
        return csv
    }

    /// Exports channel configuration to CSV.
    static func channelsToCsv(_ channels: [ChannelInfo]) -> String {
        var csv = "Index,Name,Role,PSK,UplinkEnabled,DownlinkEnabled\n"
        for ch in channels {
            csv += "\(ch.id),\(escapeCsv(ch.name)),\(ch.role),\(escapeCsv(ch.psk)),\(ch.uplinkEnabled),\(ch.downlinkEnabled)\n"
        }
        return csv
    }

    /// Exports positions from nodes to CSV (for nodes that have GPS data).
    static func positionsToCsv(_ nodes: [NodeInfo]) -> String {
        var csv = "NodeID,Name,Latitude,Longitude,Altitude,LastHeard\n"
        for node in nodes {
            guard let lat = node.latitude, let lon = node.longitude else { continue }
            let alt = node.altitude.map { String($0) } ?? ""
            let lastHeard = node.lastHeard > 0
                ? dateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(node.lastHeard)))
                : ""
            csv += "\(node.nodeId),\(escapeCsv(node.name)),\(String(format: "%.7f", lat)),\(String(format: "%.7f", lon)),\(alt),\(lastHeard)\n"
        }
        return csv
    }

    private static func escapeCsv(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return value
    }
}
