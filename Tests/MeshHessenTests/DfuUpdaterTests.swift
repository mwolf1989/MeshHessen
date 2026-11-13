import Foundation
import Testing

@testable import MeshHessen

/// Scripted world for `NordicDfuUpdater`: the running app firmware (buttonless trigger), scans and the
/// bootloader. Nothing touches Bluetooth.
private final class DfuWorld {
    enum Bootloader {
        case legacy(LegacyBootloaderPeer)
        case secure(SecureBootloaderPeer)
    }

    var appServices: [GattUUID: Set<GattUUID>] = [LegacyDfuUuids.service: [LegacyDfuUuids.controlPoint]]
    var appWriteFails = false
    var bootloader: Bootloader
    var hit = DfuScanHit(id: UUID(), name: "AdaDFU", advertisedServices: [LegacyDfuUuids.service], rssi: -50)
    var scansUntilFound = 1
    var failingConnects = 0
    var enumerationServices: [GattUUID: Set<GattUUID>]?

    private(set) var releases = 0
    private(set) var appLinks: [FakeDfuLink] = []
    private(set) var bootloaderLinks: [FakeDfuLink] = []
    private(set) var scans = 0
    private(set) var connects = 0
    var clock = ContinuousClock.now
    var clockStep: Duration = .zero

    init(_ bootloader: Bootloader) {
        self.bootloader = bootloader
    }

    func dependencies() -> NordicDfuUpdater.Dependencies {
        NordicDfuUpdater.Dependencies(
            releaseMeshLink: { [unowned self] in releases += 1 },
            connectApp: { [unowned self] in
                let link = FakeDfuLink(maxWriteLength: 20, services: appServices)
                if appWriteFails {
                    link.peer = { link, _ in
                        link.isDisconnected = true
                        throw FirmwareBleError.disconnected
                    }
                }
                appLinks.append(link)
                return link
            },
            scanBootloader: { [unowned self] _ in
                scans += 1
                return scans >= scansUntilFound ? hit : nil
            },
            connectBootloader: { [unowned self] _ in
                connects += 1
                if failingConnects > 0 {
                    failingConnects -= 1
                    throw FirmwareBleError.connectFailed("scripted")
                }
                let link: FakeDfuLink
                if let enumerationServices {
                    // First connection is the GATT enumeration.
                    self.enumerationServices = nil
                    link = FakeDfuLink(services: enumerationServices)
                } else {
                    switch bootloader {
                    case .legacy(let peer): link = peer.makeLink()
                    case .secure(let peer): link = peer.makeLink()
                    }
                }
                bootloaderLinks.append(link)
                return link
            },
            sleep: { _ in },
            now: { [unowned self] in
                clock = clock.advanced(by: clockStep)
                return clock
            }
        )
    }
}

@MainActor
@Suite("Nordic DFU updater")
struct NordicDfuUpdaterTests {
    private static let initPacket = dfuTestImage(14, seed: 2)
    private static let firmware = dfuTestImage(6000)

    private func perform(_ world: DfuWorld, recovery: Bool = false, phases: ((FirmwareTransferPhase) -> Void)? = nil) async throws {
        try await NordicDfuUpdater.perform(
            initPacket: Self.initPacket,
            firmware: Self.firmware,
            alreadyInBootloader: recovery,
            dependencies: world.dependencies(),
            progress: { phases?($0) },
            log: { _ in }
        )
    }

    @Test("Legacy happy path: release, buttonless trigger, scan, upload")
    func legacyHappyPath() async throws {
        let peer = LegacyBootloaderPeer()
        let world = DfuWorld(.legacy(peer))
        var seen: [FirmwareTransferPhase] = []
        try await perform(world) { seen.append($0) }

        #expect(world.releases == 1)
        let trigger = try #require(world.appLinks.first)
        #expect(trigger.writes == [.init(characteristic: LegacyDfuUuids.controlPoint, data: Data([0x01, 0x04]), withResponse: true)])
        #expect(trigger.subscribed == [LegacyDfuUuids.controlPoint])
        #expect(trigger.disconnectCount == 1)
        #expect(world.scans == 1)
        #expect(peer.image == Self.firmware)
        #expect(peer.activated)
        #expect(world.bootloaderLinks.allSatisfy { $0.disconnectCount == 1 })
        #expect(seen.first == .disconnecting)
        #expect(seen.contains(.triggeringBootloader))
        #expect(seen.contains(.searchingBootloader))
        #expect(seen.last == .validating)
    }

    @Test("Secure buttonless is preferred and the Secure transport is used for an FE59 bootloader")
    func secureTrigger() async throws {
        let peer = SecureBootloaderPeer()
        let world = DfuWorld(.secure(peer))
        world.appServices = [
            SecureDfuUuids.service: [SecureDfuUuids.buttonlessNoBonds],
            LegacyDfuUuids.service: [LegacyDfuUuids.controlPoint],
        ]
        world.hit = DfuScanHit(id: UUID(), name: "DfuTarg", advertisedServices: [SecureDfuUuids.service], rssi: -60)
        try await perform(world)

        let trigger = try #require(world.appLinks.first)
        #expect(trigger.writes == [.init(characteristic: SecureDfuUuids.buttonlessNoBonds, data: Data([0x01]), withResponse: true)])
        #expect(peer.received[SecureDfuObjectType.data] == Self.firmware)
    }

    @Test("A trigger write that never completes counts as success (the device reboots)")
    func triggerWriteFailureIgnored() async throws {
        let peer = LegacyBootloaderPeer()
        let world = DfuWorld(.legacy(peer))
        world.appWriteFails = true
        try await perform(world)
        #expect(peer.image == Self.firmware)
    }

    @Test("An app firmware without any DFU service stops before scanning")
    func noDfuService() async throws {
        let world = DfuWorld(.legacy(LegacyBootloaderPeer()))
        world.appServices = [:]
        await #expect(throws: DfuUpdateError.noDfuService) { try await perform(world) }
        #expect(world.scans == 0)
        #expect(world.connects == 0)
    }

    @Test("Recovery mode skips release and trigger")
    func recoveryMode() async throws {
        let peer = LegacyBootloaderPeer()
        let world = DfuWorld(.legacy(peer))
        try await perform(world, recovery: true)
        #expect(world.releases == 0)
        #expect(world.appLinks.isEmpty)
        #expect(peer.image == Self.firmware)
    }

    @Test("Three empty scans: bootloader not found")
    func notFound() async throws {
        let world = DfuWorld(.legacy(LegacyBootloaderPeer()))
        world.scansUntilFound = 99
        await #expect(throws: DfuUpdateError.bootloaderNotFound) { try await perform(world) }
        #expect(world.scans == 3)
        #expect(world.connects == 0)
    }

    @Test("No DFU UUID advertised: the protocol is detected from the GATT table")
    func detectByEnumeration() async throws {
        let peer = SecureBootloaderPeer()
        let world = DfuWorld(.secure(peer))
        world.hit = DfuScanHit(id: UUID(), name: nil, advertisedServices: [], rssi: -60)
        world.enumerationServices = [SecureDfuUuids.service: []]
        try await perform(world, recovery: true)
        #expect(peer.received[SecureDfuObjectType.data] == Self.firmware)
        #expect(world.bootloaderLinks.first?.disconnectCount == 1)
    }

    @Test("Stale Legacy session: reset over a fresh connection, then upload")
    func staleSessionReset() async throws {
        let peer = LegacyBootloaderPeer()
        peer.startStatuses = [LegacyDfuStatus.invalidState, LegacyDfuStatus.success]
        let world = DfuWorld(.legacy(peer))
        try await perform(world, recovery: true)
        #expect(peer.resets == 1)
        #expect(world.connects == 3)  // session, reset-prime, session
        #expect(peer.image == Self.firmware)
    }

    @Test("A bootloader that stays stale fails after two resets")
    func staleSessionGivesUp() async throws {
        let peer = LegacyBootloaderPeer()
        peer.startStatuses = [LegacyDfuStatus.invalidState]
        let world = DfuWorld(.legacy(peer))
        await #expect(throws: DfuUpdateError.staleSession) { try await perform(world, recovery: true) }
        #expect(peer.resets == 2)
        #expect(!peer.activated)
    }

    @Test("A mid-stream drop retries with PRN 5 and sends no abort")
    func midStreamRetry() async throws {
        let peer = LegacyBootloaderPeer()
        peer.dropAtPacket = 7
        let world = DfuWorld(.legacy(peer))
        try await perform(world, recovery: true)
        #expect(peer.prnRequests == [10, 5])
        #expect(peer.resets == 0)
        #expect(peer.image == Self.firmware)
    }

    @Test("Legacy failures: three whole-session attempts, each aborted")
    func legacyAttemptsExhausted() async throws {
        let peer = LegacyBootloaderPeer()
        peer.receiptSkew = 8
        let world = DfuWorld(.legacy(peer))
        do {
            try await perform(world, recovery: true)
            Issue.record("Expected failure")
        } catch let error as DfuUpdateError {
            guard case .failed = error else {
                Issue.record("Expected .failed, got \(error)")
                return
            }
        }
        #expect(world.connects == 3)
        #expect(peer.resets == 3)
        #expect(!peer.activated)
    }

    @Test("Connect retries up to four times per session")
    func connectRetries() async throws {
        let peer = LegacyBootloaderPeer()
        let world = DfuWorld(.legacy(peer))
        world.failingConnects = 3
        try await perform(world, recovery: true)
        #expect(world.connects == 4)
        #expect(peer.image == Self.firmware)
    }

    @Test("Cancelling mid-transfer sends RESET so the bootloader can start fresh")
    func cancelSendsAbort() async throws {
        let peer = LegacyBootloaderPeer()
        peer.cancelAtPacket = 5
        let world = DfuWorld(.legacy(peer))
        let task = Task { @MainActor in try await perform(world, recovery: true) }
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
        #expect(peer.resets == 1)
        #expect(!peer.activated)
        #expect(world.bootloaderLinks.first?.disconnectCount == 1)
    }

    @Test("Past the 5-minute pre-start budget no new session starts")
    func preStartBudget() async throws {
        let world = DfuWorld(.legacy(LegacyBootloaderPeer()))
        world.clockStep = .seconds(6 * 60)
        await #expect(throws: DfuUpdateError.startTimedOut) { try await perform(world, recovery: true) }
        #expect(world.connects == 0)
    }
}
