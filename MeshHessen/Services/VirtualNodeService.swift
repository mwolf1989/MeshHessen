import Foundation
import Network
import SwiftProtobuf

/// Cached configuration frames that are replayed to a Virtual Node client in
/// response to its own `WantConfigId` request.
struct VirtualNodeReplayCache: Sendable {
    struct Snapshot: Equatable, Sendable {
        let hasMyInfo: Bool
        let hasMetadata: Bool
        let channelCount: Int
        let configCount: Int
        let moduleConfigCount: Int
        let nodeCount: Int
        let isReady: Bool
    }

    private var myInfoFrame: Data?
    private var metadataFrame: Data?
    private var channelFrames: [Int32: Data] = [:]
    private var configFrames: [Int: Data] = [:]
    private var moduleConfigFrames: [Int: Data] = [:]
    private var nodeFrames: [UInt32: Data] = [:]
    private(set) var isReady = false

    var snapshot: Snapshot {
        Snapshot(
            hasMyInfo: myInfoFrame != nil,
            hasMetadata: metadataFrame != nil,
            channelCount: channelFrames.count,
            configCount: configFrames.count,
            moduleConfigCount: moduleConfigFrames.count,
            nodeCount: nodeFrames.count,
            isReady: isReady
        )
    }

    /// Updates the cache and returns false for physical ConfigComplete frames,
    /// which must not be broadcast because each client receives its own nonce.
    @discardableResult
    mutating func ingest(fromRadioPayload payload: Data, framedData: Data) -> Bool {
        guard let fromRadio = try? Meshtastic_FromRadio(serializedBytes: payload) else {
            return true
        }

        switch fromRadio.payloadVariant {
        case .myInfo?:
            myInfoFrame = framedData
        case .metadata?:
            metadataFrame = framedData
        case .channel(let channel)?:
            channelFrames[channel.index] = framedData
        case .config(let config)?:
            if let key = Self.configKey(config.payloadVariant) {
                configFrames[key] = framedData
            }
        case .moduleConfig(let config)?:
            if let key = Self.moduleConfigKey(config.payloadVariant) {
                moduleConfigFrames[key] = framedData
            }
        case .nodeInfo(let node)?:
            nodeFrames[node.num] = framedData
        case .configCompleteID?:
            isReady = true
            return false
        default:
            break
        }
        return true
    }

    func replayFrames(wantConfigID: UInt32) throws -> [Data] {
        var frames: [Data] = []
        if let myInfoFrame { frames.append(myInfoFrame) }
        if let metadataFrame { frames.append(metadataFrame) }
        frames.append(contentsOf: channelFrames.sorted { $0.key < $1.key }.map(\.value))
        frames.append(contentsOf: configFrames.sorted { $0.key < $1.key }.map(\.value))
        frames.append(contentsOf: moduleConfigFrames.sorted { $0.key < $1.key }.map(\.value))
        frames.append(contentsOf: nodeFrames.sorted { $0.key < $1.key }.map(\.value))

        var completion = Meshtastic_FromRadio()
        completion.configCompleteID = wantConfigID
        frames.append(try MeshtasticStreamFrameCodec.frame(completion.serializedData()))
        return frames
    }

    mutating func removeAll() {
        myInfoFrame = nil
        metadataFrame = nil
        channelFrames.removeAll(keepingCapacity: true)
        configFrames.removeAll(keepingCapacity: true)
        moduleConfigFrames.removeAll(keepingCapacity: true)
        nodeFrames.removeAll(keepingCapacity: true)
        isReady = false
    }

    private static func configKey(_ variant: Meshtastic_Config.OneOf_PayloadVariant?) -> Int? {
        switch variant {
        case .device?: return 1
        case .position?: return 2
        case .power?: return 3
        case .network?: return 4
        case .display?: return 5
        case .lora?: return 6
        case .bluetooth?: return 7
        case .security?: return 8
        case .sessionkey?: return 9
        case .deviceUi?: return 10
        case nil: return nil
        }
    }

    private static func moduleConfigKey(_ variant: Meshtastic_ModuleConfig.OneOf_PayloadVariant?) -> Int? {
        switch variant {
        case .mqtt?: return 1
        case .serial?: return 2
        case .externalNotification?: return 3
        case .storeForward?: return 4
        case .rangeTest?: return 5
        case .telemetry?: return 6
        case .cannedMessage?: return 7
        case .audio?: return 8
        case .remoteHardware?: return 9
        case .neighborInfo?: return 10
        case .ambientLighting?: return 11
        case .detectionSensor?: return 12
        case .paxcounter?: return 13
        case .statusmessage?: return 14
        case .trafficManagement?: return 15
        case .tak?: return 16
        case nil: return nil
        }
    }
}

/// TCP server that exposes a connected physical Meshtastic node to multiple
/// Meshtastic applications as a virtual Stream API device.
actor VirtualNodeService {
    struct Configuration: Equatable, Sendable {
        var port: UInt16 = 4404
        var blockAdminCommands = false
        var queueCapacity = 100
        var pacingMilliseconds = 10

        init(
            port: UInt16 = 4404,
            blockAdminCommands: Bool = false,
            queueCapacity: Int = 100,
            pacingMilliseconds: Int = 10
        ) {
            self.port = port
            self.blockAdminCommands = blockAdminCommands
            self.queueCapacity = max(1, queueCapacity)
            self.pacingMilliseconds = max(0, pacingMilliseconds)
        }
    }

    struct ClientInfo: Identifiable, Equatable, Sendable {
        let id: UUID
        let endpoint: String
        let connectedAt: Date
    }

    enum Event: Equatable, Sendable {
        case started(port: UInt16)
        case stopped
        case clientConnected(ClientInfo)
        case clientDisconnected(ClientInfo)
        case adminCommandBlocked(clientID: UUID)
        case physicalQueueDroppedOldest
        case forwardingFailed(String)
        case listenerFailed(String)
    }

    enum ServiceError: LocalizedError {
        case invalidPort
        case listenerStoppedBeforeReady

        var errorDescription: String? {
            switch self {
            case .invalidPort:
                return String(localized: "The Virtual Node port must be between 1 and 65535.")
            case .listenerStoppedBeforeReady:
                return String(localized: "The Virtual Node listener stopped before becoming ready.")
            }
        }
    }

    typealias PhysicalFrameHandler = @Sendable (Data) async throws -> Void
    typealias LocalPacketHandler = @Sendable (Data) async -> Void
    typealias EventHandler = @Sendable (Event) async -> Void

    private struct ClientState {
        let info: ClientInfo
        let connection: NWConnection
        var decoder = MeshtasticStreamFrameDecoder()
        var isReady = false
        var lastConfigID: UInt32?
        var lastConfigRequestAt = Date.distantPast
    }

    private let networkQueue = DispatchQueue(label: "dev.marcelwolf.MeshHessen.virtual-node")
    private var configuration = Configuration()
    private var listener: NWListener?
    private var listenerStartContinuation: CheckedContinuation<Void, Error>?
    private var clients: [UUID: ClientState] = [:]
    private var replayCache = VirtualNodeReplayCache()

    private var physicalFrameHandler: PhysicalFrameHandler?
    private var localPacketHandler: LocalPacketHandler?
    private var eventHandler: EventHandler?

    private var physicalQueue = BoundedDropOldestQueue<Data>(capacity: 100)
    private var physicalQueueWaiter: CheckedContinuation<Data?, Never>?
    private var physicalQueueIsFinished = true
    private var physicalSendTask: Task<Void, Never>?

    private var eventContinuations: [UUID: AsyncStream<Event>.Continuation] = [:]
    private var physicalFrameContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]
    private var localPacketContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    private(set) var isRunning = false

    init(physicalFrameHandler: PhysicalFrameHandler? = nil) {
        self.physicalFrameHandler = physicalFrameHandler
    }

    func setPhysicalFrameHandler(_ handler: PhysicalFrameHandler?) {
        physicalFrameHandler = handler
    }

    func setLocalPacketHandler(_ handler: LocalPacketHandler?) {
        localPacketHandler = handler
    }

    func setEventHandler(_ handler: EventHandler?) {
        eventHandler = handler
    }

    /// Updates the security gate without restarting the listener. Kiosk mode can
    /// use this to force admin blocking for already connected clients.
    func setBlockAdminCommands(_ blocked: Bool) {
        configuration.blockAdminCommands = blocked
    }

    func currentConfiguration() -> Configuration {
        configuration
    }

    func events() -> AsyncStream<Event> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        eventContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeEventContinuation(id) }
        }
        return stream
    }

    /// Every accepted, fully framed client message that is queued for the
    /// physical connection. Local heartbeat/config/disconnect messages are omitted.
    func framesForPhysical() -> AsyncStream<Data> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        physicalFrameContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removePhysicalFrameContinuation(id) }
        }
        return stream
    }

    /// Outgoing client MeshPackets represented as raw FromRadio protobuf bytes,
    /// allowing the host application to display them immediately.
    func localPackets() -> AsyncStream<Data> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Data.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        localPacketContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeLocalPacketContinuation(id) }
        }
        return stream
    }

    func connectedClients() -> [ClientInfo] {
        clients.values
            .filter(\.isReady)
            .map(\.info)
            .sorted { $0.connectedAt < $1.connectedAt }
    }

    func cacheSnapshot() -> VirtualNodeReplayCache.Snapshot {
        replayCache.snapshot
    }

    func start(configuration: Configuration = Configuration()) async throws {
        if isRunning { return }
        guard configuration.port > 0,
              let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw ServiceError.invalidPort
        }

        self.configuration = configuration
        physicalQueue = BoundedDropOldestQueue(capacity: configuration.queueCapacity)
        physicalQueueIsFinished = false

        let listener = try NWListener(using: .tcp, on: port)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleListenerState(state) }
        }

        physicalSendTask = Task { [weak self] in
            await self?.processPhysicalQueue()
        }

        do {
            try await withCheckedThrowingContinuation { continuation in
                listenerStartContinuation = continuation
                listener.start(queue: networkQueue)
            }
        } catch {
            await stop()
            throw error
        }
    }

    func stop() async {
        let wasRunning = isRunning || listener != nil
        isRunning = false
        listener?.cancel()
        listener = nil
        if let continuation = listenerStartContinuation {
            listenerStartContinuation = nil
            continuation.resume(throwing: ServiceError.listenerStoppedBeforeReady)
        }

        for client in clients.values {
            client.connection.cancel()
        }
        clients.removeAll()

        finishPhysicalQueue()
        physicalSendTask?.cancel()
        physicalSendTask = nil

        if wasRunning {
            await emit(.stopped)
        }
    }

    /// Accepts one complete framed FromRadio packet from the physical node,
    /// updates replay state, and broadcasts it to all Virtual Node clients.
    func ingestPhysicalFrame(_ frame: Data) async throws {
        let payload = try MeshtasticStreamFrameCodec.payload(from: frame)
        let shouldBroadcast = replayCache.ingest(fromRadioPayload: payload, framedData: frame)
        if shouldBroadcast {
            await broadcast(frame)
        }
    }

    /// Convenience entry point for transports such as BLE that expose raw
    /// FromRadio protobuf bytes rather than Stream API frames.
    func ingestPhysicalPayload(_ payload: Data) async throws {
        let frame = try MeshtasticStreamFrameCodec.frame(payload)
        let shouldBroadcast = replayCache.ingest(fromRadioPayload: payload, framedData: frame)
        if shouldBroadcast {
            await broadcast(frame)
        }
    }

    func clearReplayCache() {
        replayCache.removeAll()
    }

    // MARK: - Listener

    private func handleListenerState(_ state: NWListener.State) async {
        switch state {
        case .ready:
            isRunning = true
            if let continuation = listenerStartContinuation {
                listenerStartContinuation = nil
                continuation.resume()
            }
            await emit(.started(port: configuration.port))
        case .failed(let error):
            if let continuation = listenerStartContinuation {
                listenerStartContinuation = nil
                continuation.resume(throwing: error)
            }
            isRunning = false
            await emit(.listenerFailed(error.localizedDescription))
        case .cancelled:
            if let continuation = listenerStartContinuation {
                listenerStartContinuation = nil
                continuation.resume(throwing: ServiceError.listenerStoppedBeforeReady)
            }
        default:
            break
        }
    }

    private func accept(_ connection: NWConnection) {
        let id = UUID()
        let info = ClientInfo(
            id: id,
            endpoint: String(describing: connection.endpoint),
            connectedAt: Date()
        )
        clients[id] = ClientState(info: info, connection: connection)

        connection.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleClientState(state, id: id) }
        }
        connection.start(queue: networkQueue)
    }

    private func handleClientState(_ state: NWConnection.State, id: UUID) async {
        switch state {
        case .ready:
            guard var client = clients[id], !client.isReady else { return }
            client.isReady = true
            clients[id] = client
            await emit(.clientConnected(client.info))
            receiveNext(from: id)
        case .failed, .cancelled:
            await removeClient(id)
        default:
            break
        }
    }

    private func receiveNext(from id: UUID) {
        guard let connection = clients[id]?.connection else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task {
                await self?.handleReceivedData(data, from: id, isComplete: isComplete, error: error)
            }
        }
    }

    private func handleReceivedData(
        _ data: Data?,
        from id: UUID,
        isComplete: Bool,
        error: NWError?
    ) async {
        guard var client = clients[id] else { return }
        if let data, !data.isEmpty {
            let payloads = client.decoder.append(data)
            clients[id] = client
            for payload in payloads {
                await handleClientPayload(payload, from: id)
            }
        }

        if error != nil || isComplete {
            await removeClient(id)
        } else if clients[id] != nil {
            receiveNext(from: id)
        }
    }

    private func removeClient(_ id: UUID) async {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.cancel()
        if client.isReady {
            await emit(.clientDisconnected(client.info))
        }
    }

    // MARK: - Client Protocol

    private func handleClientPayload(_ payload: Data, from id: UUID) async {
        guard var client = clients[id],
              let toRadio = try? Meshtastic_ToRadio(serializedBytes: payload) else {
            return
        }

        switch toRadio.payloadVariant {
        case .wantConfigID(let configID)?:
            let now = Date()
            let isDuplicate = client.lastConfigID == configID
                && now.timeIntervalSince(client.lastConfigRequestAt) < 5
            client.lastConfigID = configID
            client.lastConfigRequestAt = now
            clients[id] = client
            guard !isDuplicate else { return }
            await sendReplay(to: id, wantConfigID: configID)
            return

        case .disconnect?:
            return

        case .heartbeat?:
            var status = Meshtastic_QueueStatus()
            status.res = 0
            status.free = 16
            status.maxlen = 32
            var fromRadio = Meshtastic_FromRadio()
            fromRadio.queueStatus = status
            if let frame = try? MeshtasticStreamFrameCodec.frame(fromRadio.serializedData()) {
                _ = await send(frame, to: id)
            }
            return

        case .packet(let packet)?:
            if configuration.blockAdminCommands,
               MeshtasticStreamFrameCodec.containsAdminCommand(payload) {
                await emit(.adminCommandBlocked(clientID: id))
                return
            }

            var fromRadio = Meshtastic_FromRadio()
            fromRadio.packet = packet
            if let localPayload = try? fromRadio.serializedData() {
                localPacketContinuations.values.forEach { $0.yield(localPayload) }
                if let localPacketHandler {
                    await localPacketHandler(localPayload)
                }
                if let localFrame = try? MeshtasticStreamFrameCodec.frame(localPayload) {
                    await broadcast(localFrame, excluding: id)
                }
            }

        default:
            break
        }

        guard let framedData = try? MeshtasticStreamFrameCodec.frame(payload) else { return }
        await enqueueForPhysical(framedData)
    }

    private func sendReplay(to id: UUID, wantConfigID: UInt32) async {
        guard let frames = try? replayCache.replayFrames(wantConfigID: wantConfigID) else { return }
        for frame in frames {
            guard await send(frame, to: id) else { return }
            await pace()
        }
    }

    // MARK: - Physical Queue

    private func enqueueForPhysical(_ frame: Data) async {
        physicalFrameContinuations.values.forEach { $0.yield(frame) }
        if let waiter = physicalQueueWaiter {
            physicalQueueWaiter = nil
            waiter.resume(returning: frame)
        } else if physicalQueue.enqueue(frame) != nil {
            await emit(.physicalQueueDroppedOldest)
        }
    }

    private func nextPhysicalFrame() async -> Data? {
        if let frame = physicalQueue.dequeue() { return frame }
        if physicalQueueIsFinished { return nil }
        return await withCheckedContinuation { continuation in
            physicalQueueWaiter = continuation
        }
    }

    private func finishPhysicalQueue() {
        physicalQueueIsFinished = true
        physicalQueue.removeAll()
        if let waiter = physicalQueueWaiter {
            physicalQueueWaiter = nil
            waiter.resume(returning: nil)
        }
    }

    private func processPhysicalQueue() async {
        while !Task.isCancelled, let frame = await nextPhysicalFrame() {
            guard let physicalFrameHandler else {
                await emit(.forwardingFailed(String(localized: "No physical frame handler is configured.")))
                continue
            }
            do {
                try await physicalFrameHandler(frame)
            } catch {
                await emit(.forwardingFailed(error.localizedDescription))
            }
            await pace()
        }
    }

    // MARK: - Sending

    @discardableResult
    private func send(_ frame: Data, to id: UUID) async -> Bool {
        guard let connection = clients[id]?.connection else { return false }
        return await withCheckedContinuation { continuation in
            connection.send(content: frame, completion: .contentProcessed { error in
                continuation.resume(returning: error == nil)
            })
        }
    }

    private func broadcast(_ frame: Data, excluding excludedID: UUID? = nil) async {
        let ids = clients.keys.filter { $0 != excludedID }
        for id in ids {
            _ = await send(frame, to: id)
        }
    }

    private func pace() async {
        guard configuration.pacingMilliseconds > 0 else { return }
        try? await Task.sleep(for: .milliseconds(configuration.pacingMilliseconds))
    }

    private func emit(_ event: Event) async {
        eventContinuations.values.forEach { $0.yield(event) }
        if let eventHandler {
            await eventHandler(event)
        }
    }

    private func removeEventContinuation(_ id: UUID) {
        eventContinuations.removeValue(forKey: id)
    }

    private func removePhysicalFrameContinuation(_ id: UUID) {
        physicalFrameContinuations.removeValue(forKey: id)
    }

    private func removeLocalPacketContinuation(_ id: UUID) {
        localPacketContinuations.removeValue(forKey: id)
    }
}
