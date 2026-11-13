import Foundation

/// LoRa airtime estimation (Semtech SX127x formula) for the Funk-Echo "reply airtime" tile.
/// Preset parameters mirror the firmware's `modemPresetToParams()` in `src/mesh/MeshRadio.h`
/// (non-wide LoRa values, i.e. EU868); the preamble is 16 symbols and the over-the-air
/// Meshtastic header is 16 bytes. Ported from the Windows client's `LoRaAirtime.cs`.
enum LoRaAirtime {
    /// `MESHTASTIC_HEADER_LENGTH`.
    static let otaHeaderBytes = 16
    /// `RadioInterface.preambleLength`.
    static let preambleSymbols = 16

    typealias Parameters = (sf: Int, bwKHz: Double, cr: Int)

    // MARK: - Presets

    /// Spreading factor, bandwidth (kHz) and coding-rate denominator of a modem preset.
    /// nil = unknown preset; callers must then hide the estimate instead of guessing.
    static func parameters(for preset: Meshtastic_Config.LoRaConfig.ModemPreset) -> Parameters? {
        switch preset {
        case .longFast: return (11, 250.0, 5)
        case .longSlow: return (12, 125.0, 8)
        case .longModerate: return (11, 125.0, 8)
        case .longTurbo: return (11, 500.0, 8)
        case .mediumSlow: return (10, 250.0, 5)
        case .mediumFast: return (9, 250.0, 5)
        case .mediumTurbo: return (9, 500.0, 5)
        case .shortSlow: return (8, 250.0, 5)
        case .shortFast: return (7, 250.0, 5)
        case .shortTurbo: return (7, 500.0, 5)
        case .liteFast: return (9, 125.0, 5)
        case .liteSlow: return (10, 125.0, 5)
        case .narrowFast: return (7, 62.5, 6)
        case .narrowSlow: return (8, 62.5, 6)
        case .tinyFast: return (7, 15.6, 5)
        case .tinySlow: return (8, 15.6, 6)
        case .veryLongSlow, .UNRECOGNIZED: return nil
        }
    }

    // MARK: - Airtime

    /// Airtime of one LoRa packet in milliseconds (explicit header, CRC on). Low-data-rate
    /// optimisation switches on automatically above 16 ms symbol time, matching common
    /// radio drivers. `payloadBytes` is the full packet length including the OTA header.
    static func airtimeMs(
        payloadBytes: Int,
        sf: Int,
        bwKHz: Double,
        cr: Int,
        preambleSymbols: Int = preambleSymbols
    ) -> Double {
        let symbolMs = pow(2, Double(sf)) / bwKHz
        let lowDataRateOptimisation = symbolMs > 16.0
        let preambleMs = (Double(preambleSymbols) + 4.25) * symbolMs

        let de = lowDataRateOptimisation ? 1 : 0
        let crBits = min(max(cr, 5), 8) - 4
        let numerator = Double(8 * payloadBytes - 4 * sf + 28 + 16)
        let payloadSymbols = 8 + max(
            (numerator / Double(4 * (sf - 2 * de))).rounded(.up) * Double(crBits + 4),
            0
        )
        return preambleMs + payloadSymbols * symbolMs
    }

    // MARK: - Replies

    /// Rough OTA size (bytes including the 16-byte header) of the firmware's automatic reply
    /// to a request — deliberately conservative averages. `hops` = relays in the stored
    /// route of a traceroute request.
    static func replyPayloadBytes(type: RequestEchoType, detail: String?, hops: Int?) -> Int {
        switch type {
        case .nodeInfo:
            return otaHeaderBytes + 50
        case .position:
            return otaHeaderBytes + 30
        case .telemetry:
            return otaHeaderBytes + (detail == RequestEchoTelemetryDetail.localStats.rawValue ? 45 : 32)
        case .traceroute:
            // RouteDiscovery grows with the path: id (4 B) + SNR (1 B) per hop, both directions.
            return otaHeaderBytes + 12 + 6 * max((hops ?? 0) + 1, 1)
        case .admin:
            return otaHeaderBytes + 30
        }
    }

    /// Only certain replies count (`yes` / `prec:*`), so the estimate never overstates
    /// what our node transmits.
    static func isCertainReply(expected: String?) -> Bool {
        guard let expected else { return false }
        return expected == "yes" || expected.hasPrefix("prec:")
    }

    /// Estimated airtime of one expected reply; nil for uncertain replies or unknown presets.
    static func replyAirtimeMs(
        type: RequestEchoType,
        detail: String?,
        hops: Int?,
        expected: String?,
        preset: Meshtastic_Config.LoRaConfig.ModemPreset
    ) -> Double? {
        guard isCertainReply(expected: expected), let parameters = parameters(for: preset) else { return nil }
        let bytes = replyPayloadBytes(type: type, detail: detail, hops: hops)
        return airtimeMs(payloadBytes: bytes, sf: parameters.sf, bwKHz: parameters.bwKHz, cr: parameters.cr)
    }

    /// Sum of `count × reply airtime` over journal rows; nil when the preset is unknown.
    static func totalReplyAirtimeMs(
        records: [RequestEchoRecord],
        preset: Meshtastic_Config.LoRaConfig.ModemPreset
    ) -> Double? {
        guard parameters(for: preset) != nil else { return nil }
        return records.reduce(0) { total, record in
            guard let type = record.type,
                  let ms = replyAirtimeMs(
                    type: type,
                    detail: record.detail,
                    hops: record.routeNodeIds.count,
                    expected: record.expected,
                    preset: preset
                  )
            else { return total }
            return total + ms * Double(record.count)
        }
    }

    /// "≈ 1.2 s" / "≈ 640 ms".
    static func formatted(ms: Double) -> String {
        ms >= 1_000
            ? String(format: "≈ %.1f s", ms / 1_000)
            : String(format: "≈ %.0f ms", ms)
    }
}
