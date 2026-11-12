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
}
