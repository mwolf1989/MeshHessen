import Foundation
import Observation

// MARK: - Model

/// One scheduled request: ask `nodeId` for `type` every `intervalMinutes`.
struct TelemetryPollEntry: Codable, Hashable, Identifiable, Sendable {
    var nodeId: UInt32
    var type: NodeInfoRequestType
    var intervalMinutes: Int
    /// Persisted so a restart does not re-poll everything at once.
    var lastSentUtc: Date?

    var id: String { "\(nodeId)-\(type.rawValue)" }
}

enum TelemetryPollingError: LocalizedError, Equatable, Sendable {
    case tooManyNodes

    var errorDescription: String? {
        switch self {
        case .tooManyNodes:
            return String(localized: "At most \(TelemetryPollPlan.maxNodes) nodes can be polled.")
        }
    }
}

/// The polling plan. Mesh etiquette limits are enforced here, not only in the UI:
/// at most `maxNodes` distinct nodes, local stats at most hourly, everything else at
/// most every 30 minutes, and at most one request per minute overall.
struct TelemetryPollPlan: Codable, Equatable, Sendable {
    static let maxNodes = 4
    static let minimumRequestSpacing: TimeInterval = 60

    /// Request types that make sense to poll (telemetry the node may not broadcast).
    static let allowedTypes: [NodeInfoRequestType] = [
        .localStats, .environmentMetrics, .deviceMetrics, .airQualityMetrics, .powerMetrics,
    ]

    static func minimumIntervalMinutes(for type: NodeInfoRequestType) -> Int {
        type == .localStats ? 60 : 30
    }

    var enabled: Bool = true
    var entries: [TelemetryPollEntry] = []

    /// Validates and normalises `entries`: unknown node 0 and non-pollable types are
    /// dropped, duplicates (node + type) collapse, intervals are raised to the
    /// per-type minimum, and `lastSentUtc` of entries already in `previous` is kept.
    /// Throws when more than `maxNodes` distinct nodes would be polled.
    static func normalized(
        enabled: Bool,
        entries: [TelemetryPollEntry],
        previous: [TelemetryPollEntry] = []
    ) throws -> TelemetryPollPlan {
        var cleaned: [TelemetryPollEntry] = []
        for entry in entries where entry.nodeId != 0 && allowedTypes.contains(entry.type) {
            guard !cleaned.contains(where: { $0.id == entry.id }) else { continue }
            var normalized = entry
            normalized.intervalMinutes = max(entry.intervalMinutes, minimumIntervalMinutes(for: entry.type))
            normalized.lastSentUtc = previous.first(where: { $0.id == entry.id })?.lastSentUtc
                ?? entry.lastSentUtc
            cleaned.append(normalized)
        }
        guard Set(cleaned.map(\.nodeId)).count <= maxNodes else {
            throw TelemetryPollingError.tooManyNodes
        }
        return TelemetryPollPlan(enabled: enabled, entries: cleaned)
    }

    /// The entry to request now, or nil. Nothing is due within `minimumRequestSpacing`
    /// of the last request; otherwise the most overdue due entry wins (never sent first).
    static func nextDue(
        entries: [TelemetryPollEntry],
        now: Date,
        lastRequestAt: Date?
    ) -> TelemetryPollEntry? {
        if let lastRequestAt, now.timeIntervalSince(lastRequestAt) < minimumRequestSpacing {
            return nil
        }
        return entries
            .filter { entry in
                guard let sent = entry.lastSentUtc else { return true }
                return now.timeIntervalSince(sent) >= TimeInterval(entry.intervalMinutes) * 60
            }
            .min { lhs, rhs in
                (lhs.lastSentUtc ?? .distantPast) < (rhs.lastSentUtc ?? .distantPast)
            }
    }
}

// MARK: - Service

/// App-wide scheduler that polls selected nodes for telemetry they do not broadcast
/// on their own. Edited from the telemetry dashboard; runs while connected
/// (`AppCoordinator` starts and stops it). Polling costs airtime — keep the limits.
@Observable
@MainActor
final class TelemetryPollingService {
    typealias RequestSender = @MainActor (NodeInfoRequestType, UInt32) async -> Bool

    static let tickInterval: Duration = .seconds(60)

    private(set) var plan: TelemetryPollPlan
    private(set) var isRunning = false

    @ObservationIgnored private let fileURL: URL
    @ObservationIgnored private var lastRequestAt: Date?
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var isSending = false

    init(fileURL: URL = TelemetryPollingService.defaultFileURL()) {
        self.fileURL = fileURL
        self.plan = Self.load(from: fileURL)
    }

    nonisolated static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("MeshHessen", isDirectory: true)
            .appendingPathComponent("telemetry_polling.json")
    }

    // MARK: - Editing

    /// Replaces the plan after validation; see `TelemetryPollPlan.normalized`.
    func updatePlan(enabled: Bool, entries: [TelemetryPollEntry]) throws {
        plan = try TelemetryPollPlan.normalized(enabled: enabled, entries: entries, previous: plan.entries)
        save()
    }

    func setEnabled(_ enabled: Bool) {
        plan.enabled = enabled
        save()
    }

    func addEntry(nodeId: UInt32, type: NodeInfoRequestType, intervalMinutes: Int) throws {
        let entry = TelemetryPollEntry(nodeId: nodeId, type: type, intervalMinutes: intervalMinutes)
        try updatePlan(
            enabled: plan.enabled,
            entries: plan.entries.filter { $0.id != entry.id } + [entry]
        )
    }

    func removeEntry(id: TelemetryPollEntry.ID) {
        plan.entries.removeAll { $0.id == id }
        save()
    }

    // MARK: - Scheduling

    /// Starts the 60-second loop. Call when the radio link is ready.
    func start(send: @escaping RequestSender) {
        stop()
        isRunning = true
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                guard !Task.isCancelled, let self else { return }
                await self.tick(now: Date(), send: send)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
    }

    /// Sends at most one due request. The entry is marked sent even if sending
    /// fails, so a broken link never causes retry hammering.
    @discardableResult
    func tick(now: Date, send: RequestSender) async -> TelemetryPollEntry? {
        guard plan.enabled, !isSending,
              let due = TelemetryPollPlan.nextDue(
                entries: plan.entries,
                now: now,
                lastRequestAt: latestRequest
              ),
              let index = plan.entries.firstIndex(where: { $0.id == due.id })
        else { return nil }

        plan.entries[index].lastSentUtc = now
        lastRequestAt = now
        save()

        isSending = true
        defer { isSending = false }
        let sent = await send(due.type, due.nodeId)
        AppLogger.shared.log(
            "[Polling] \(due.type.rawValue) request to \(String(format: "!%08x", due.nodeId)) "
                + "(every \(due.intervalMinutes) min) \(sent ? "sent" : "failed")",
            debug: true
        )
        return due
    }

    /// The most recent request, including ones persisted before a restart.
    private var latestRequest: Date? {
        ([lastRequestAt] + plan.entries.map(\.lastSentUtc)).compactMap { $0 }.max()
    }

    // MARK: - Persistence

    private static func load(from url: URL) -> TelemetryPollPlan {
        guard let data = try? Data(contentsOf: url) else { return TelemetryPollPlan() }
        do {
            let decoded = try decoder.decode(TelemetryPollPlan.self, from: data)
            return (try? TelemetryPollPlan.normalized(enabled: decoded.enabled, entries: decoded.entries))
                ?? TelemetryPollPlan(enabled: decoded.enabled)
        } catch {
            AppLogger.shared.log("[Polling] Could not read \(url.lastPathComponent): \(error)")
            return TelemetryPollPlan()
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Self.encoder.encode(plan).write(to: fileURL, options: .atomic)
        } catch {
            AppLogger.shared.log("[Polling] Could not save \(fileURL.lastPathComponent): \(error)")
        }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
