import Foundation
import Testing

@testable import MeshHessen

/// The firmware closes its client API 15 min after the last ToRadio it received;
/// the client heartbeats every 5 min and treats missing heartbeat replies as a
/// dead link. Ported from the Windows client's `LinkWatchdogTests.cs`.
/// `#expect` cannot call mutating members on a captured struct, so the tests
/// drive the watchdog through this reference wrapper.
private final class WatchdogProbe {
    var watchdog = LinkWatchdog()

    func isStale(_ now: Date) -> Bool {
        watchdog.checkStale(now: now)
    }
}

@Suite("Link Watchdog")
struct LinkWatchdogTests {
    private static let t0 = Date(timeIntervalSince1970: 1_794_243_600) // 2026-11-09 17:00 UTC

    private func minute(_ value: Double) -> Date {
        Self.t0.addingTimeInterval(value * 60)
    }

    @Test("A fresh watchdog never reports a stale link")
    func freshWatchdogIsNotStale() {
        let probe = WatchdogProbe()
        #expect(probe.watchdog.lastFrameAt == nil)
        #expect(!probe.isStale(minute(0)))
        #expect(!probe.isStale(minute(100)))
    }

    @Test("Heartbeat interval is five minutes")
    func heartbeatInterval() {
        #expect(LinkWatchdog.heartbeatInterval == 300)
    }

    @Test("A device that answers heartbeats is stale after two unanswered probes")
    func answeringDeviceStaleAfterTwoUnansweredProbes() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(0))
        probe.watchdog.onHeartbeatSent(now: minute(5))
        probe.watchdog.onFrameReceived(isQueueStatus: true, now: minute(5.01)) // reply → device supports probes
        #expect(probe.watchdog.deviceAnswersHeartbeats)

        probe.watchdog.onHeartbeatSent(now: minute(10))  // unanswered
        #expect(!probe.isStale(minute(15)))  // one miss is tolerated
        probe.watchdog.onHeartbeatSent(now: minute(15))  // second unanswered
        #expect(probe.isStale(minute(20)))
        #expect(!probe.isStale(minute(25)))  // reported once per silence

        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(26)) // traffic again → armed anew
        probe.watchdog.onHeartbeatSent(now: minute(30))
        probe.watchdog.onHeartbeatSent(now: minute(35))
        #expect(probe.isStale(minute(40)))
    }

    @Test("Two unanswered probes need more than five minutes of silence")
    func unansweredProbesNeedSilence() {
        let probe = WatchdogProbe()
        probe.watchdog.onHeartbeatSent(now: minute(0))
        probe.watchdog.onFrameReceived(isQueueStatus: true, now: minute(0.01))
        probe.watchdog.onHeartbeatSent(now: minute(1))
        probe.watchdog.onHeartbeatSent(now: minute(2))
        #expect(probe.watchdog.heartbeatsSinceLastFrame == 2)
        #expect(!probe.isStale(minute(4)))
        #expect(probe.isStale(minute(5.5)))
    }

    @Test("A device that never answers only counts long total silence")
    func silentDeviceOnlyCountsLongSilence() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(0))
        for index in 1...8 {
            probe.watchdog.onHeartbeatSent(now: minute(Double(5 * index))) // 40 min of unanswered probes
        }
        #expect(!probe.watchdog.deviceAnswersHeartbeats)
        #expect(!probe.isStale(minute(40)))  // quiet mesh on old firmware is not an error
        #expect(!probe.isStale(minute(44)))
        #expect(probe.isStale(minute(46)))  // but 45+ min without any frame is
    }

    @Test("Any frame resets the silence clock")
    func anyFrameResetsSilence() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(0))
        probe.watchdog.onHeartbeatSent(now: minute(5))
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(40))
        #expect(probe.watchdog.heartbeatsSinceLastFrame == 0)
        #expect(!probe.isStale(minute(46)))  // only 6 min since the last frame
        #expect(!probe.isStale(minute(85)))
        #expect(probe.isStale(minute(86)))
    }

    @Test("Stale is reported once until a frame arrives")
    func staleReportedOnce() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(0))
        #expect(probe.isStale(minute(46)))
        #expect(!probe.isStale(minute(50)))
        #expect(!probe.isStale(minute(200)))

        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(201))
        #expect(!probe.isStale(minute(202)))
        #expect(probe.isStale(minute(247)))
    }

    @Test("A queueStatus long after a heartbeat does not count as its reply")
    func lateQueueStatusIsNoReply() {
        let probe = WatchdogProbe()
        probe.watchdog.onHeartbeatSent(now: minute(0))
        probe.watchdog.onFrameReceived(isQueueStatus: true, now: minute(3)) // > 1 min later: unrelated
        #expect(!probe.watchdog.deviceAnswersHeartbeats)
        #expect(!probe.isStale(minute(10)))
    }

    @Test("A queueStatus without any heartbeat does not count as a reply")
    func queueStatusWithoutHeartbeat() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: true, now: minute(0))
        #expect(!probe.watchdog.deviceAnswersHeartbeats)
    }

    @Test("Reset forgets everything and starts a new silence period")
    func resetForgetsEverything() {
        let probe = WatchdogProbe()
        probe.watchdog.onHeartbeatSent(now: minute(0))
        probe.watchdog.onFrameReceived(isQueueStatus: true, now: minute(0.1))
        probe.watchdog.onHeartbeatSent(now: minute(5))
        #expect(probe.watchdog.deviceAnswersHeartbeats)

        probe.watchdog.reset(now: minute(10))
        #expect(!probe.watchdog.deviceAnswersHeartbeats)
        #expect(probe.watchdog.heartbeatsSinceLastFrame == 0)
        #expect(probe.watchdog.lastHeartbeatAt == nil)
        #expect(probe.watchdog.lastFrameAt == minute(10))
        #expect(!probe.isStale(minute(54)))  // falls back to the silence rule
        #expect(probe.isStale(minute(56)))  // a link that never speaks again is caught
    }

    @Test("Reset re-arms a stale report")
    func resetRearmsStaleReport() {
        let probe = WatchdogProbe()
        probe.watchdog.onFrameReceived(isQueueStatus: false, now: minute(0))
        #expect(probe.isStale(minute(46)))
        probe.watchdog.reset(now: minute(50))
        #expect(probe.isStale(minute(96)))
    }

    @Test("Heartbeat is a plain keepalive with nonce 0")
    func heartbeatWireFormat() throws {
        let toRadio = MeshtasticProtocolService.makeHeartbeat()
        guard case .heartbeat(let heartbeat) = toRadio.payloadVariant else {
            Issue.record("Expected a heartbeat payload, got \(String(describing: toRadio.payloadVariant))")
            return
        }
        // A non-zero nonce makes the firmware broadcast its NodeInfo on the mesh.
        #expect(heartbeat.nonce == 0)
        let decoded = try Meshtastic_ToRadio(serializedBytes: try toRadio.serializedData())
        #expect(decoded == toRadio)
    }
}

@Suite("Link Watchdog – protocol wiring and handshake metadata")
@MainActor
struct LinkWatchdogProtocolTests {
    private let myNodeID: UInt32 = 0x1234_ABCD

    private func makeHarness() -> (service: MeshtasticProtocolService, state: AppState, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshHessen-LinkWatchdogTests-\(UUID().uuidString)", isDirectory: true)
        let database = TelemetryDatabaseService(
            databaseURL: directory.appendingPathComponent("telemetry.sqlite"),
            retentionDays: 0
        )
        let service = MeshtasticProtocolService(telemetryDatabase: database)
        let state = AppState()
        service.appState = state
        return (service, state, directory)
    }

    /// Feeds a FromRadio as if it came from the physical device (serial/TCP framing).
    private func receiveFromDevice(_ fromRadio: Meshtastic_FromRadio, on service: MeshtasticProtocolService) throws {
        let payload = try fromRadio.serializedData()
        var frame = Data([0x94, 0xC3, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)])
        frame.append(payload)
        service.onDataReceived(frame)
    }

    private func myInfoFrame(pioEnv: String) -> Meshtastic_FromRadio {
        var info = Meshtastic_MyNodeInfo()
        info.myNodeNum = myNodeID
        info.pioEnv = pioEnv
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.myInfo = info
        return fromRadio
    }

    private func metadataFrame() -> Meshtastic_FromRadio {
        var meta = Meshtastic_DeviceMetadata()
        meta.firmwareVersion = "2.8.2.abcdef"
        meta.hwModel = .heltecV3
        meta.hasWifi_p = true
        meta.hasBluetooth_p = true
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.metadata = meta
        return fromRadio
    }

    private func ownNodeInfoFrame() -> Meshtastic_FromRadio {
        var user = Meshtastic_User()
        user.id = String(format: "!%08x", myNodeID)
        user.shortName = "MH"
        user.longName = "Mesh Hessen Test"
        var info = Meshtastic_NodeInfo()
        info.num = myNodeID
        info.user = user
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.nodeInfo = info
        return fromRadio
    }

    @Test("Frames from the device feed the watchdog")
    func deviceFramesFeedWatchdog() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        #expect(harness.service.linkWatchdogState.lastFrameAt == nil)

        var queueStatus = Meshtastic_FromRadio()
        queueStatus.queueStatus = Meshtastic_QueueStatus()
        try receiveFromDevice(queueStatus, on: harness.service)

        let lastFrame = try #require(harness.service.linkWatchdogState.lastFrameAt)
        #expect(Date().timeIntervalSince(lastFrame) < 5)
    }

    @Test("Frames synthesised for Virtual Node clients do not count as link activity")
    func virtualFramesDoNotFeedWatchdog() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        var queueStatus = Meshtastic_FromRadio()
        queueStatus.queueStatus = Meshtastic_QueueStatus()
        harness.service.onVirtualFromRadioPayload(try queueStatus.serializedData())
        #expect(harness.service.linkWatchdogState.lastFrameAt == nil)
    }

    @Test("Metadata arriving before the own NodeInfo is kept and survives its re-creation")
    func metadataBeforeNodeInfo() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try receiveFromDevice(myInfoFrame(pioEnv: "heltec-v3"), on: harness.service)
        #expect(harness.state.myNodeInfo == nil)

        try receiveFromDevice(metadataFrame(), on: harness.service)
        let early = try #require(harness.state.myNodeInfo)
        #expect(early.nodeId == myNodeID)
        #expect(early.shortName.isEmpty)
        #expect(early.firmwareVersion == "2.8.2.abcdef")
        #expect(early.hardwareModelRaw == Meshtastic_HardwareModel.heltecV3.rawValue)
        #expect(early.pioEnv == "heltec-v3")
        #expect(early.hasWifi)
        #expect(early.hasBluetooth)
        #expect(harness.service.deviceMetadata?.firmwareVersion == "2.8.2.abcdef")

        try receiveFromDevice(ownNodeInfoFrame(), on: harness.service)
        let full = try #require(harness.state.myNodeInfo)
        #expect(full.longName == "Mesh Hessen Test")
        #expect(full.firmwareVersion == "2.8.2.abcdef")
        #expect(full.hardwareModelRaw == Meshtastic_HardwareModel.heltecV3.rawValue)
        #expect(full.pioEnv == "heltec-v3")
        #expect(full.hasWifi)
        #expect(full.hasBluetooth)
    }

    @Test("Metadata after the own NodeInfo updates it in place")
    func metadataAfterNodeInfo() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }

        try receiveFromDevice(myInfoFrame(pioEnv: "rak4631"), on: harness.service)
        try receiveFromDevice(ownNodeInfoFrame(), on: harness.service)
        #expect(harness.state.myNodeInfo?.pioEnv == "rak4631")
        #expect(harness.state.myNodeInfo?.firmwareVersion == "")

        try receiveFromDevice(metadataFrame(), on: harness.service)
        let info = try #require(harness.state.myNodeInfo)
        #expect(info.longName == "Mesh Hessen Test")
        #expect(info.firmwareVersion == "2.8.2.abcdef")
        #expect(info.hasBluetooth)
    }

    @Test("Disconnect clears the cached device metadata")
    func disconnectClearsMetadata() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try receiveFromDevice(myInfoFrame(pioEnv: "heltec-v3"), on: harness.service)
        try receiveFromDevice(metadataFrame(), on: harness.service)
        #expect(harness.service.deviceMetadata != nil)

        harness.service.disconnect()
        #expect(harness.service.deviceMetadata == nil)
    }

    @Test("ClientNotification frames reach the callback")
    func clientNotificationCallback() throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        var received: [String] = []
        harness.service.onClientNotification = { received.append($0.message) }

        var note = Meshtastic_ClientNotification()
        note.message = "Duty cycle limit reached"
        note.level = .warning
        var fromRadio = Meshtastic_FromRadio()
        fromRadio.clientNotification = note
        try receiveFromDevice(fromRadio, on: harness.service)

        #expect(received == ["Duty cycle limit reached"])
    }

    @Test("A missing Bluetooth service is a permanent connection error")
    func serviceNotFoundIsPermanent() {
        #expect(ConnectionError.serviceNotFound.isPermanent)
        #expect(ConnectionError.serviceNotFound.errorDescription?.contains("Forget This Device") == true)
        #expect(!ConnectionError.timeout.isPermanent)
    }
}
