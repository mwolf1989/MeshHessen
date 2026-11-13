import Foundation
import Testing

@testable import MeshHessen

/// Telemetry polling plan: etiquette limits, scheduling and persistence.
@Suite("Telemetry Polling")
@MainActor
struct TelemetryPollingTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(
        _ node: UInt32,
        _ type: NodeInfoRequestType = .localStats,
        every minutes: Int = 60,
        sentMinutesAgo: Double? = nil
    ) -> TelemetryPollEntry {
        TelemetryPollEntry(
            nodeId: node,
            type: type,
            intervalMinutes: minutes,
            lastSentUtc: sentMinutesAgo.map { Self.now.addingTimeInterval(-$0 * 60) }
        )
    }

    private func makeFileURL() -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-PollingTests-\(UUID().uuidString)", isDirectory: true)
        return (directory.appendingPathComponent("telemetry_polling.json"), directory)
    }

    // MARK: - Limits

    @Test("At most four distinct nodes; several types per node are fine")
    func nodeLimit() throws {
        let four = (1...4).map { entry(UInt32($0)) } + [entry(1, .environmentMetrics, every: 30)]
        let plan = try TelemetryPollPlan.normalized(enabled: true, entries: four)
        #expect(plan.entries.count == 5)

        #expect(throws: TelemetryPollingError.tooManyNodes) {
            try TelemetryPollPlan.normalized(enabled: true, entries: (1...5).map { entry(UInt32($0)) })
        }
    }

    @Test("Intervals are raised to 60 min for local stats and 30 min otherwise")
    func minimumIntervals() throws {
        let plan = try TelemetryPollPlan.normalized(enabled: true, entries: [
            entry(1, .localStats, every: 5),
            entry(1, .deviceMetrics, every: 10),
            entry(2, .environmentMetrics, every: 45),
        ])
        #expect(plan.entries.map(\.intervalMinutes) == [60, 30, 45])
    }

    @Test("Duplicates, node 0 and non-telemetry types are dropped; last-sent times survive edits")
    func normalisation() throws {
        let sent = Self.now.addingTimeInterval(-600)
        var previous = entry(1)
        previous.lastSentUtc = sent
        let plan = try TelemetryPollPlan.normalized(
            enabled: false,
            entries: [entry(1), entry(1, every: 120), entry(0), entry(2, .userInfo), entry(3, .position)],
            previous: [previous]
        )
        #expect(!plan.enabled)
        #expect(plan.entries.count == 1)
        #expect(plan.entries.first?.lastSentUtc == sent)
    }

    // MARK: - Scheduling

    @Test("nextDue respects each entry's interval and picks the most overdue")
    func nextDueIntervals() {
        let entries = [
            entry(1, every: 60, sentMinutesAgo: 30),   // not due
            entry(2, every: 60, sentMinutesAgo: 90),   // due
            entry(3, every: 60, sentMinutesAgo: 200),  // most overdue
        ]
        #expect(TelemetryPollPlan.nextDue(entries: entries, now: Self.now, lastRequestAt: nil)?.nodeId == 3)
        #expect(TelemetryPollPlan.nextDue(entries: [entries[0]], now: Self.now, lastRequestAt: nil) == nil)
        #expect(TelemetryPollPlan.nextDue(entries: [], now: Self.now, lastRequestAt: nil) == nil)
    }

    @Test("Never-sent entries are due first")
    func neverSentFirst() {
        let entries = [entry(1, every: 60, sentMinutesAgo: 500), entry(2)]
        #expect(TelemetryPollPlan.nextDue(entries: entries, now: Self.now, lastRequestAt: nil)?.nodeId == 2)
    }

    @Test("At most one request per minute overall")
    func oneRequestPerMinute() {
        let entries = [entry(1), entry(2)]
        #expect(TelemetryPollPlan.nextDue(
            entries: entries, now: Self.now, lastRequestAt: Self.now.addingTimeInterval(-30)
        ) == nil)
        #expect(TelemetryPollPlan.nextDue(
            entries: entries, now: Self.now, lastRequestAt: Self.now.addingTimeInterval(-60)
        ) != nil)
    }

    @Test("A tick sends one request, marks it sent and then waits a minute")
    func tickSendsOne() async throws {
        let (url, directory) = makeFileURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TelemetryPollingService(fileURL: url)
        try service.updatePlan(enabled: true, entries: [entry(1), entry(2, .environmentMetrics, every: 30)])

        var sent: [(NodeInfoRequestType, UInt32)] = []
        let send: TelemetryPollingService.RequestSender = { type, node in
            sent.append((type, node))
            return true
        }
        #expect(await service.tick(now: Self.now, send: send) != nil)
        #expect(await service.tick(now: Self.now.addingTimeInterval(30), send: send) == nil)
        #expect(await service.tick(now: Self.now.addingTimeInterval(61), send: send) != nil)
        #expect(await service.tick(now: Self.now.addingTimeInterval(130), send: send) == nil)
        #expect(sent.map(\.1).sorted() == [1, 2])
        #expect(service.plan.entries.allSatisfy { $0.lastSentUtc != nil })
    }

    @Test("A disabled plan sends nothing")
    func disabledPlan() async throws {
        let (url, directory) = makeFileURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        let service = TelemetryPollingService(fileURL: url)
        try service.updatePlan(enabled: false, entries: [entry(1)])

        var count = 0
        await service.tick(now: Self.now) { _, _ in
            count += 1
            return true
        }
        #expect(count == 0)
    }

    // MARK: - Persistence

    @Test("The plan round-trips through telemetry_polling.json")
    func jsonRoundTrip() throws {
        let (url, directory) = makeFileURL()
        defer { try? FileManager.default.removeItem(at: directory) }

        let service = TelemetryPollingService(fileURL: url)
        try service.updatePlan(enabled: false, entries: [
            entry(0x1234, .localStats, every: 90, sentMinutesAgo: 10),
            entry(0x5678, .powerMetrics, every: 30),
        ])
        #expect(FileManager.default.fileExists(atPath: url.path))

        let reloaded = TelemetryPollingService(fileURL: url)
        #expect(reloaded.plan == service.plan)
        #expect(!reloaded.plan.enabled)
        #expect(reloaded.plan.entries.first?.lastSentUtc == Self.now.addingTimeInterval(-600))
    }

    @Test("A missing or corrupt file yields an empty, enabled plan")
    func corruptFile() throws {
        let (url, directory) = makeFileURL()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(TelemetryPollingService(fileURL: url).plan == TelemetryPollPlan())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let service = TelemetryPollingService(fileURL: url)
        #expect(service.plan.enabled)
        #expect(service.plan.entries.isEmpty)
    }
}
