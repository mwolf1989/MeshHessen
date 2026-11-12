import Foundation

/// Liveness bookkeeping for the device link.
///
/// The firmware closes its client API 15 minutes after the last `ToRadio` it
/// received from us and then silently stops delivering packets, while the
/// port/socket stays open. The protocol service therefore sends a heartbeat
/// every ``heartbeatInterval``. Firmware ≥ 2.8 answers each heartbeat with a
/// `queueStatus` frame, which doubles as a probe: two unanswered probes in a
/// row mean the link is dead. Older firmware never answers, so for those only
/// a long total silence (``silentFallback``) counts as stale.
///
/// Pure logic with injected time — no timers. Ported from the Windows client's
/// `LinkWatchdog.cs`.
struct LinkWatchdog {
    static let heartbeatInterval: TimeInterval = 300
    /// Stale verdict for devices that never answered a heartbeat: no frame at all for this long.
    static let silentFallback: TimeInterval = 45 * 60
    /// A `queueStatus` this soon after a heartbeat counts as its reply.
    static let heartbeatReplyWindow: TimeInterval = 60
    /// Heartbeats without any frame before a device known to answer them is considered gone.
    static let maxUnansweredProbes = 2

    private(set) var lastFrameAt: Date?
    private(set) var lastHeartbeatAt: Date?
    private(set) var heartbeatsSinceLastFrame = 0
    private(set) var deviceAnswersHeartbeats = false
    private var staleReported = false

    /// Forgets everything and starts a new silence period at `now`, so a link
    /// that never delivers another frame is still detected.
    mutating func reset(now: Date) {
        lastFrameAt = now
        lastHeartbeatAt = nil
        heartbeatsSinceLastFrame = 0
        deviceAnswersHeartbeats = false
        staleReported = false
    }

    mutating func onHeartbeatSent(now: Date) {
        lastHeartbeatAt = now
        heartbeatsSinceLastFrame += 1
    }

    /// Any FromRadio frame arrived. `isQueueStatus` marks the heartbeat reply.
    mutating func onFrameReceived(isQueueStatus: Bool, now: Date) {
        lastFrameAt = now
        if isQueueStatus,
           let lastHeartbeatAt,
           now.timeIntervalSince(lastHeartbeatAt) < Self.heartbeatReplyWindow {
            deviceAnswersHeartbeats = true
        }
        heartbeatsSinceLastFrame = 0
        staleReported = false
    }

    /// True at most once per silence period when the link should be considered dead.
    mutating func checkStale(now: Date) -> Bool {
        guard !staleReported, let lastFrameAt else { return false }
        let silence = now.timeIntervalSince(lastFrameAt)
        let stale = deviceAnswersHeartbeats
            ? heartbeatsSinceLastFrame >= Self.maxUnansweredProbes && silence > Self.heartbeatInterval
            : silence > Self.silentFallback
        if stale { staleReported = true }
        return stale
    }

    func describe(now: Date) -> String {
        guard let lastFrameAt else { return "no frame received yet" }
        let minutes = now.timeIntervalSince(lastFrameAt) / 60
        return String(
            format: "last frame %.1f min ago, %d heartbeat(s) unanswered, answersHeartbeats=%@",
            minutes,
            heartbeatsSinceLastFrame,
            deviceAnswersHeartbeats ? "true" : "false"
        )
    }
}
