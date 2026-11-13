import Foundation
import Testing

@testable import MeshHessen

// Funk-Echo: classification of directed requests aimed at our node, the reply
// expectation and the journal's burst aggregation (ported from the Windows tests).

private let me: UInt32 = 0xAABB_CCDD

private func packet(
    from: UInt32,
    to: UInt32,
    port: Meshtastic_PortNum,
    wantResponse: Bool,
    requestId: UInt32 = 0,
    hopStart: UInt32 = 3,
    hopLimit: UInt32 = 3,
    viaMqtt: Bool = false,
    payload: Data = Data()
) -> Meshtastic_MeshPacket {
    var data = Meshtastic_Data()
    data.portnum = port
    data.wantResponse = wantResponse
    data.requestID = requestId
    data.payload = payload
    var packet = Meshtastic_MeshPacket()
    packet.from = from
    packet.to = to
    packet.id = 42
    packet.hopStart = hopStart
    packet.hopLimit = hopLimit
    packet.viaMqtt = viaMqtt
    packet.decoded = data
    return packet
}

@Suite("RequestEcho classifier")
struct RequestEchoClassifierTests {
    @Test("Directed want-response requests classify", arguments: [
        (Meshtastic_PortNum.nodeinfoApp, RequestEchoType.nodeInfo),
        (.positionApp, .position),
        (.telemetryApp, .telemetry),
        (.tracerouteApp, .traceroute),
    ])
    func directedRequests(port: Meshtastic_PortNum, expected: RequestEchoType) {
        let result = RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: port, wantResponse: true)
        )
        #expect(result == expected)
    }

    @Test("Admin packets count even without want_response")
    func adminWithoutWantResponse() {
        let result = RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: .adminApp, wantResponse: false)
        )
        #expect(result == .admin)
    }

    @Test("Broadcasts and overheard packets are ignored")
    func broadcastsIgnored() {
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: 0xFFFF_FFFF, port: .nodeinfoApp, wantResponse: true)
        ) == nil)
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: 0x222, port: .nodeinfoApp, wantResponse: true)
        ) == nil)
    }

    @Test("Replies to our own requests are ignored")
    func repliesIgnored() {
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: .nodeinfoApp, wantResponse: false, requestId: 99)
        ) == nil)
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: .adminApp, wantResponse: false, requestId: 99)
        ) == nil)
    }

    @Test("Plain packets without want_response are ignored")
    func plainPacketsIgnored() {
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: .nodeinfoApp, wantResponse: false)
        ) == nil)
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0x111, to: me, port: .textMessageApp, wantResponse: true)
        ) == nil)
    }

    @Test("Own, sender-less and unknown-own-id packets are ignored")
    func ownPacketsIgnored() {
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: me, to: me, port: .positionApp, wantResponse: true)
        ) == nil)
        #expect(RequestEchoClassifier.type(
            myNodeId: me,
            packet: packet(from: 0, to: me, port: .positionApp, wantResponse: true)
        ) == nil)
        #expect(RequestEchoClassifier.type(
            myNodeId: 0,
            packet: packet(from: 0x111, to: 0, port: .positionApp, wantResponse: true)
        ) == nil)
    }

    @Test("Telemetry variant is extracted from the request payload", arguments: [
        "Device", "Environment", "Power", "AirQuality", "LocalStats", "Host",
    ])
    func telemetryVariant(variant: String) throws {
        var telemetry = Meshtastic_Telemetry()
        switch variant {
        case "Device": telemetry.deviceMetrics = Meshtastic_DeviceMetrics()
        case "Environment": telemetry.environmentMetrics = Meshtastic_EnvironmentMetrics()
        case "Power": telemetry.powerMetrics = Meshtastic_PowerMetrics()
        case "AirQuality": telemetry.airQualityMetrics = Meshtastic_AirQualityMetrics()
        case "LocalStats": telemetry.localStats = Meshtastic_LocalStats()
        case "Host": telemetry.hostMetrics = Meshtastic_HostMetrics()
        default: Issue.record("unexpected variant \(variant)")
        }
        let pkt = packet(
            from: 0x111, to: me, port: .telemetryApp, wantResponse: true,
            payload: try telemetry.serializedData()
        )
        #expect(RequestEchoClassifier.type(myNodeId: me, packet: pkt) == .telemetry)
        #expect(RequestEchoClassifier.telemetryVariant(of: pkt) == variant)
        #expect(RequestEchoClassifier.classify(myNodeId: me, packet: pkt)?.detail == variant)
    }

    @Test("Soil/water telemetry counts as environment")
    func soilWaterIsEnvironment() throws {
        var telemetry = Meshtastic_Telemetry()
        telemetry.soilWaterMetrics = Meshtastic_SoilWaterMetrics()
        let pkt = packet(
            from: 0x111, to: me, port: .telemetryApp, wantResponse: true,
            payload: try telemetry.serializedData()
        )
        #expect(RequestEchoClassifier.type(myNodeId: me, packet: pkt) == .telemetry)
        #expect(RequestEchoClassifier.telemetryVariant(of: pkt) == "Environment")
    }

    @Test("Telemetry variant is nil for an empty or foreign payload")
    func telemetryVariantNil() {
        #expect(RequestEchoClassifier.telemetryVariant(
            of: packet(from: 0x111, to: me, port: .telemetryApp, wantResponse: true)
        ) == nil)
        #expect(RequestEchoClassifier.telemetryVariant(
            of: packet(from: 0x111, to: me, port: .nodeinfoApp, wantResponse: true)
        ) == nil)
    }

    @Test("Traceroute route towards us is extracted")
    func tracerouteRoute() throws {
        var discovery = Meshtastic_RouteDiscovery()
        discovery.route = [0x10, 0x20]
        let pkt = packet(
            from: 0x111, to: me, port: .tracerouteApp, wantResponse: true,
            payload: try discovery.serializedData()
        )
        #expect(RequestEchoClassifier.route(of: pkt) == [0x10, 0x20])
        let event = RequestEchoClassifier.classify(myNodeId: me, packet: pkt)
        #expect(event?.route == [0x10, 0x20])
        #expect(event?.routeText == "!00000010,!00000020")
    }

    @Test("Hop count follows the packet_rx rule")
    func hopCount() {
        #expect(RequestEchoClassifier.hops(of: packet(
            from: 1, to: me, port: .positionApp, wantResponse: true, hopStart: 3, hopLimit: 1
        )) == 2)
        #expect(RequestEchoClassifier.hops(of: packet(
            from: 1, to: me, port: .positionApp, wantResponse: true, hopStart: 0, hopLimit: 0
        )) == nil)
        #expect(RequestEchoClassifier.hops(of: packet(
            from: 1, to: me, port: .positionApp, wantResponse: true, hopStart: 2, hopLimit: 3
        )) == nil)
        #expect(RequestEchoClassifier.hops(of: packet(
            from: 1, to: me, port: .positionApp, wantResponse: true, hopStart: 3, hopLimit: 3
        )) == 0)
    }
}

@Suite("RequestEcho expectation")
struct RequestEchoExpectationTests {
    @Test("Expectation is derived from local state", arguments: [
        // NodeInfo/Traceroute: modules always answer
        (RequestEchoType.nodeInfo, String?.none, true, UInt32(32), "yes"),
        (.traceroute, nil, false, 0, "yes"),
        // Position: depends on own position + channel precision
        (.position, nil, false, 32, "no-pos"),
        (.position, nil, true, 32, "yes"),
        (.position, nil, true, 0, "yes"),
        (.position, nil, true, 13, "prec:13"),
        // Telemetry: device/local stats always, sensors unknown
        (.telemetry, "Device", true, 32, "yes"),
        (.telemetry, "LocalStats", true, 32, "yes"),
        (.telemetry, "Environment", true, 32, "sensor"),
        (.telemetry, nil, true, 32, "sensor"),
        // Admin: authorisation-gated
        (.admin, nil, true, 32, "auth"),
    ])
    func expectation(
        type: RequestEchoType,
        detail: String?,
        hasPosition: Bool,
        precision: UInt32,
        expected: String
    ) {
        #expect(RequestEchoExpectation.compute(
            type: type,
            detail: detail,
            hasOwnPosition: hasPosition,
            channelPrecisionBits: precision
        ) == expected)
    }

    @Test("Precision bits map to the Windows radius")
    func precisionRadius() {
        #expect(RequestEchoExpectation.precisionRadiusKm(bits: 0) == 0)
        #expect(RequestEchoExpectation.precisionRadiusKm(bits: 32) == 0)
        let km = RequestEchoExpectation.precisionRadiusKm(bits: 13)
        #expect(abs(km - 2.918) < 0.01)
        #expect(RequestEchoExpectation.text(for: "prec:13")?.contains("2.9 km") == true)
        #expect(RequestEchoExpectation.text(for: nil) == nil)
    }

    @Test("No message text claims a request was answered")
    func noAnsweredClaim() {
        var texts: [String] = []
        for type in RequestEchoType.allCases {
            for tone in RequestEchoTone.allCases {
                texts.append(RequestEchoText.message(type: type, from: "KELL", detail: nil, tone: tone))
                texts.append(RequestEchoText.message(type: type, from: "KELL", detail: "Power", tone: tone))
            }
        }
        for code in ["yes", "prec:13", "no-pos", "sensor", "auth"] {
            texts.append(RequestEchoExpectation.text(for: code) ?? "")
        }
        for text in texts {
            #expect(!text.lowercased().contains("answered"), "\(text)")
            #expect(!text.lowercased().contains("beantwortet"), "\(text)")
        }
    }
}

@Suite("RequestEcho aggregation")
@MainActor
struct RequestEchoAggregationTests {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-RequestEchoTests-\(UUID().uuidString)", isDirectory: true)
        return (
            TelemetryDatabaseService(
                databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
                retentionDays: 0,
                clock: { Self.now }
            ),
            directory
        )
    }

    private func event(
        _ from: UInt32,
        _ type: RequestEchoType,
        at timestamp: Date,
        detail: String? = nil
    ) -> RequestEchoEvent {
        RequestEchoEvent(fromId: from, type: type, timestamp: timestamp, hops: 0, viaMqtt: false, detail: detail)
    }

    @Test("Two events 5 min apart become one row with count 2; 11 min apart split")
    func burstWindow() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Self.now.addingTimeInterval(-3_600)

        database.upsertRequestEcho(event(0x111, .telemetry, at: t0), expected: "sensor")
        database.upsertRequestEcho(event(0x111, .telemetry, at: t0.addingTimeInterval(300)), expected: "sensor")
        database.upsertRequestEcho(event(0x222, .position, at: t0), expected: "yes")
        database.upsertRequestEcho(event(0x222, .position, at: t0.addingTimeInterval(660)), expected: "yes")
        database.waitForPendingWrites()

        let journal = database.requestEchoJournal(since: t0.addingTimeInterval(-60))
        let telemetryRows = journal.filter { $0.nodeId == 0x111 }
        #expect(telemetryRows.count == 1)
        #expect(telemetryRows.first?.count == 2)
        #expect(telemetryRows.first?.lastSeen == t0.addingTimeInterval(300))
        #expect(telemetryRows.first?.firstSeen == t0)
        #expect(telemetryRows.first?.expected == "sensor")
        let positionRows = journal.filter { $0.nodeId == 0x222 }
        #expect(positionRows.count == 2)
        #expect(positionRows.allSatisfy { $0.count == 1 })
        // newest first
        #expect(journal.first?.lastSeen == t0.addingTimeInterval(660))
    }

    @Test("Bursts and stats aggregate like Windows")
    func windowsAggregation() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Self.now.addingTimeInterval(-30 * 60)

        database.upsertRequestEcho(event(0x111, .telemetry, at: t0), expected: nil)
        database.upsertRequestEcho(event(0x111, .telemetry, at: t0.addingTimeInterval(300)), expected: nil)
        // Same node, different type → own row
        database.upsertRequestEcho(event(0x111, .position, at: t0.addingTimeInterval(300)), expected: nil)
        // Same type but outside the 10-min window → new burst
        database.upsertRequestEcho(event(0x111, .telemetry, at: t0.addingTimeInterval(1_200)), expected: nil)
        database.waitForPendingWrites()

        let journal = database.requestEchoJournal(since: t0.addingTimeInterval(-60))
        #expect(journal.count == 3)
        #expect(journal.first { $0.type == .telemetry && $0.count > 1 }?.count == 2)

        let stats = database.requestEchoStats(days: 1)
        #expect(stats.totalRequests == 4)
        #expect(stats.stations == 1)
        #expect(stats.perType["telemetry"] == 3)
        #expect(stats.perType["position"] == 1)
        #expect(stats.topNodes.first?.nodeId == 0x111)
        #expect(stats.traceCount == 0)
    }

    @Test("Different telemetry details stay separate bursts")
    func differentDetailsSplit() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Self.now.addingTimeInterval(-300)

        database.upsertRequestEcho(event(0x111, .telemetry, at: t0, detail: "Environment"), expected: nil)
        database.upsertRequestEcho(event(0x111, .telemetry, at: t0.addingTimeInterval(60), detail: "Power"), expected: nil)
        database.upsertRequestEcho(
            event(0x111, .telemetry, at: t0.addingTimeInterval(120), detail: "Environment"),
            expected: nil
        )
        database.waitForPendingWrites()

        let journal = database.requestEchoJournal(since: t0.addingTimeInterval(-60))
        #expect(journal.count == 2)
        #expect(journal.first { $0.detail == "Environment" }?.count == 2)
        #expect(journal.first { $0.detail == "Power" }?.count == 1)
    }

    @Test("Stats break telemetry down by detail")
    func statsByDetail() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Self.now.addingTimeInterval(-3_600)

        database.upsertRequestEcho(event(0x111, .telemetry, at: t0, detail: "Environment"), expected: nil)
        database.upsertRequestEcho(event(0x222, .telemetry, at: t0, detail: "Environment"), expected: nil)
        database.upsertRequestEcho(event(0x111, .telemetry, at: t0, detail: "Power"), expected: nil)
        database.upsertRequestEcho(event(0x111, .position, at: t0), expected: nil)
        database.upsertRequestEcho(event(0x333, .traceroute, at: t0), expected: nil)
        database.waitForPendingWrites()

        let stats = database.requestEchoStats(days: 1)
        #expect(stats.perType["telemetry"] == 3)
        #expect(stats.telemetryDetails["Environment"] == 2)
        #expect(stats.telemetryDetails["Power"] == 1)
        #expect(stats.telemetryDetails["Position"] == nil)
        #expect(stats.stations == 3)
        #expect(stats.traceCount == 1)
    }

    @Test("Funk-Echo time series buckets requests per hour")
    func funkEchoSeries() {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let hour = Date(timeIntervalSince1970: 1_799_996_400) // full hour, 1 h before `now`
        let early = hour.addingTimeInterval(-3 * 3_600)

        database.upsertRequestEcho(event(0x111, .telemetry, at: early.addingTimeInterval(300)), expected: nil)
        database.upsertRequestEcho(event(0x111, .telemetry, at: early.addingTimeInterval(480)), expected: nil)
        database.upsertRequestEcho(event(0x111, .position, at: early.addingTimeInterval(600)), expected: nil)
        database.upsertRequestEcho(event(0x111, .nodeInfo, at: early.addingTimeInterval(7_200)), expected: nil)
        database.waitForPendingWrites()

        let series = database.getTimeSeries(nodeIds: [0x111], metric: .funkEcho, days: 0)
            .sorted { $0.timestamp < $1.timestamp }
        #expect(series.count == 2)
        #expect(series.first?.value == 3)
        #expect(series.last?.value == 1)
        if let first = series.first, let last = series.last {
            #expect(last.timestamp.timeIntervalSince(first.timestamp) == 7_200)
        }
    }

    @Test("Retention and clearing remove Funk-Echo rows")
    func retentionAndClear() async throws {
        let (database, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }

        database.upsertRequestEcho(event(0x111, .nodeInfo, at: Self.now.addingTimeInterval(-10 * 86_400)), expected: nil)
        database.upsertRequestEcho(event(0x222, .nodeInfo, at: Self.now.addingTimeInterval(-60)), expected: nil)
        database.runRetentionCleanup(retentionDays: 7, now: Self.now)
        database.waitForPendingWrites()

        let remaining = database.requestEchoJournal(since: .distantPast)
        #expect(remaining.map(\.nodeId) == [0x222])

        let deleted = try await database.clearAllTelemetry()
        #expect(deleted == 1)
        #expect(database.requestEchoJournal(since: .distantPast).isEmpty)
    }
}

@Suite("RequestEcho settings")
struct RequestEchoSettingsTests {
    @Test("Settings defaults match Windows and persist")
    func settingsDefaults() throws {
        let suite = "RequestEchoSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = SettingsService(defaults: defaults)
        #expect(settings.funkEchoEnabled)
        #expect(settings.funkEchoToneValue == .casual)
        #expect(!settings.funkEchoNotifications)
        #expect(!settings.funkEchoQuiet)

        settings.funkEchoEnabled = false
        settings.funkEchoTone = RequestEchoTone.factual.rawValue
        settings.funkEchoQuiet = true
        let reloaded = SettingsService(defaults: defaults)
        #expect(!reloaded.funkEchoEnabled)
        #expect(reloaded.funkEchoToneValue == .factual)
        #expect(reloaded.funkEchoQuiet)
    }

    @Test("Kiosk mask has a Funk-Echo bit")
    func kioskBit() {
        #expect(KioskFeatureMask.funkEcho.rawValue == 1 << 11)
        #expect(KioskFeatureMask.allCases.contains(.funkEcho))
        #expect(KioskFeatureMask.all.contains(.funkEcho))
        #expect(KioskFeatureMask.funkEcho.localizedName == "Funk-Echo")
    }

    @Test("Channel position precision is read from module settings")
    func channelPrecision() {
        var channel = Meshtastic_Channel()
        channel.index = 1
        channel.settings.moduleSettings.positionPrecision = 13
        #expect(MeshtasticProtocolService.channelInfo(from: channel).positionPrecision == 13)
    }
}
