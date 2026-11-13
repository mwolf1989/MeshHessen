import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/UnifiedOta.cs

/// ESP32 "Unified OTA" loader protocol (meshtastic/firmware-ota): line-oriented text over BLE or TCP.
/// Host → `OTA <size> <sha256hex>\n`; loader → `ERASING` (0…n) then `OK`, or `ERR …`; then the raw
/// firmware bytes; the loader answers `ACK` per receive-buffer drain (BLE) and a terminal `OK` once the
/// whole image arrived and its hash verified, or `ERR Hash Mismatch`.
enum UnifiedOta {
    enum Response: Equatable, Sendable {
        /// `OK`, optionally followed by loader details (`<hw> <fw> <rebootCount> <gitHash>`).
        case ok(details: String?)
        case erasing
        case ack
        case error(String)
        case unknown(String)
    }

    /// Loader identification carried by a detailed `OK` (`OK <hw> <fw> <rebootCount> <gitHash>`).
    struct LoaderInfo: Equatable, Sendable {
        let hardwareVersion: String
        let firmwareVersion: String
        let rebootCount: Int?
        let gitHash: String

        init?(details: String) {
            let parts = details.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count == 4 else { return nil }
            hardwareVersion = parts[0]
            firmwareVersion = parts[1]
            rebootCount = Int(parts[2])
            gitHash = parts[3]
        }
    }

    /// `"OTA <size> <sha256 lowercase hex>\n"`.
    static func startCommand(size: Int, sha256: Data) -> String {
        let hex = sha256.map { String(format: "%02x", $0) }.joined()
        return "OTA \(size) \(hex)\n"
    }

    static func parse(line: String) -> Response {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        switch text {
        case "OK":
            return .ok(details: nil)
        case "ERASING":
            return .erasing
        case "ACK":
            return .ack
        case "ERR":
            return .error("")
        default:
            break
        }
        if text.hasPrefix("OK ") {
            let details = text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return .ok(details: details.isEmpty ? nil : details)
        }
        if text.hasPrefix("ERR ") {
            return .error(text.dropFirst(4).trimmingCharacters(in: .whitespaces))
        }
        return .unknown(text)
    }
}
