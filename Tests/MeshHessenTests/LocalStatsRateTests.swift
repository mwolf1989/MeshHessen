import Foundation
import Testing

@testable import MeshHessen

/// Per-hour rates derived from the cumulative LocalStats counters.
@Suite("LocalStats Rates")
struct LocalStatsRateTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeDatabase() -> (TelemetryDatabaseService, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-LocalStatsRateTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("telemetry.sqlite")
        return (
            TelemetryDatabaseService(databaseURL: url, retentionDays: 0, clock: { Self.now }),
            directory
        )
    }

    private func insert(_ db: TelemetryDatabaseService, _ timestamp: Date, rx: Double, node: UInt32 = 1) {
        db.insertLocalStatsTelemetry(
            nodeId: node,
            timestamp: timestamp,
            sample: LocalTelemetrySample(packetsRx: rx)
        )
    }

    // MARK: - Pure helper

    @Test("Rate is the counter delta per hour between consecutive samples")
    func normalDelta() {
        let t0 = Self.now.addingTimeInterval(-3 * 3_600)
        let rates = TelemetryDatabaseService.counterRates([
            (t0, 1_000),
            (t0.addingTimeInterval(3_600), 1_060),
            (t0.addingTimeInterval(3 * 3_600), 1_100),
        ])
        #expect(rates.map(\.0) == [t0.addingTimeInterval(3_600), t0.addingTimeInterval(3 * 3_600)])
        #expect(rates.map(\.1) == [60, 20])
    }

    @Test("A counter reset after a reboot is skipped")
    func rebootResetSkipped() {
        let t0 = Self.now.addingTimeInterval(-2 * 3_600)
        let rates = TelemetryDatabaseService.counterRates([
            (t0, 5_000),
            (t0.addingTimeInterval(3_600), 12),
            (t0.addingTimeInterval(2 * 3_600), 72),
        ])
        #expect(rates.map(\.1) == [60])
    }

    @Test("Gaps under one minute or over 24 hours are skipped")
    func degenerateIntervalsSkipped() {
        let t0 = Self.now.addingTimeInterval(-30 * 3_600)
        let rates = TelemetryDatabaseService.counterRates([
            (t0, 100),
            (t0.addingTimeInterval(20), 101),
            (t0.addingTimeInterval(28 * 3_600), 200),
        ])
        #expect(rates.isEmpty)
    }

    @Test("Interval bounds of exactly one minute and 24 hours are kept")
    func boundsInclusive() {
        let t0 = Self.now.addingTimeInterval(-48 * 3_600)
        let rates = TelemetryDatabaseService.counterRates([
            (t0, 0),
            (t0.addingTimeInterval(60), 1),
            (t0.addingTimeInterval(60 + 86_400), 49),
        ])
        #expect(rates.map(\.1) == [60, 2])
    }

    @Test("Unordered input is sorted first; fewer than two samples give no rate")
    func ordering() {
        let t0 = Self.now
        #expect(TelemetryDatabaseService.counterRates([]).isEmpty)
        #expect(TelemetryDatabaseService.counterRates([(t0, 5)]).isEmpty)
        let rates = TelemetryDatabaseService.counterRates([
            (t0.addingTimeInterval(7_200), 30),
            (t0, 10),
        ])
        #expect(rates.map(\.1) == [10])
    }

    // MARK: - Database series

    @Test("Rate metrics map to their counters")
    func metricMapping() {
        #expect(TelemetrySeriesMetric.localRxPerHour.counterMetric == .localPacketsRx)
        #expect(TelemetrySeriesMetric.localTxPerHour.counterMetric == .localPacketsTx)
        #expect(TelemetrySeriesMetric.localRxBadPerHour.counterMetric == .localPacketsRxBad)
        #expect(TelemetrySeriesMetric.localRxDupePerHour.counterMetric == .localRxDuplicates)
        #expect(TelemetrySeriesMetric.localTxRelayPerHour.counterMetric == .localTxRelays)
        #expect(TelemetrySeriesMetric.localPacketsRx.counterMetric == nil)
        #expect(TelemetrySeriesMetric.localRxPerHour.rawValue == "local_rx_pph")
    }

    @Test("The time series of a rate metric is derived from stored counters per node")
    func databaseSeries() {
        let (db, directory) = makeDatabase()
        defer { try? FileManager.default.removeItem(at: directory) }
        let t0 = Self.now.addingTimeInterval(-3 * 3_600)
        insert(db, t0, rx: 1_000)
        insert(db, t0.addingTimeInterval(3_600), rx: 1_060)
        insert(db, t0.addingTimeInterval(3 * 3_600), rx: 1_100)
        insert(db, t0, rx: 10, node: 2)
        insert(db, t0.addingTimeInterval(3_600), rx: 5, node: 2)   // reboot
        insert(db, t0.addingTimeInterval(2 * 3_600), rx: 35, node: 2)
        db.waitForPendingWrites()

        let points = db.getTimeSeries(nodeIds: [1, 2], metric: .localRxPerHour, days: 0)
        let nodeOne = points.filter { $0.nodeId == 1 }
        let nodeTwo = points.filter { $0.nodeId == 2 }
        #expect(nodeOne.map(\.value) == [60, 20])
        #expect(nodeOne.map(\.timestamp) == [t0.addingTimeInterval(3_600), t0.addingTimeInterval(3 * 3_600)])
        #expect(nodeTwo.map(\.value) == [30])
        #expect(points.map(\.timestamp) == points.map(\.timestamp).sorted())

        #expect(db.getTimeSeries(nodeIds: [1], metric: .localTxPerHour, days: 0).isEmpty)
    }
}
