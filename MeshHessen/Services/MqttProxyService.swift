import Foundation
import Network

/// Bidirectional MQTT 3.1.1 proxy for Meshtastic's `proxy_to_client_enabled`
/// mode. Mutable network state is actor-isolated and credentials are never
/// included in status events or logs.
actor MqttProxyService {
    struct Configuration: Equatable, Sendable {
        let host: String
        let port: UInt16
        let useTLS: Bool
        let username: String?
        let password: String?
        let rootTopic: String
        let clientID: String
        let keepAliveSeconds: UInt16
        let reconnectDelaySeconds: Int

        init(
            host: String,
            port: UInt16,
            useTLS: Bool,
            username: String? = nil,
            password: String? = nil,
            rootTopic: String = "msh",
            clientID: String,
            keepAliveSeconds: UInt16 = 60,
            reconnectDelaySeconds: Int = 5
        ) throws {
            let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedHost.isEmpty, port > 0 else {
                throw ProxyError.invalidBrokerAddress
            }
            self.host = trimmedHost
            self.port = port
            self.useTLS = useTLS
            self.username = username
            self.password = password
            self.rootTopic = Self.normalizedRootTopic(rootTopic)
            self.clientID = clientID
            self.keepAliveSeconds = max(1, keepAliveSeconds)
            self.reconnectDelaySeconds = max(1, reconnectDelaySeconds)
        }

        init(
            mqttConfig: Meshtastic_ModuleConfig.MQTTConfig,
            myNodeID: UInt32,
            appVersion: String
        ) throws {
            let endpoint = try MQTTBrokerEndpoint.parse(
                mqttConfig.address,
                useTLS: mqttConfig.tlsEnabled
            )
            try self.init(
                host: endpoint.host,
                port: endpoint.port,
                useTLS: mqttConfig.tlsEnabled,
                username: mqttConfig.username.isEmpty ? nil : mqttConfig.username,
                password: mqttConfig.password.isEmpty ? nil : mqttConfig.password,
                rootTopic: mqttConfig.root,
                clientID: "meshhessenclient-\(appVersion)-!\(String(format: "%08x", myNodeID))"
            )
        }

        var subscriptionTopic: String { "\(rootTopic)/#" }

        private static func normalizedRootTopic(_ root: String) -> String {
            let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return trimmed.isEmpty ? "msh" : trimmed
        }
    }

    enum State: Equatable, Sendable {
        case stopped
        case connecting(host: String, port: UInt16)
        case connected(host: String, port: UInt16, clientID: String)
        case waitingToReconnect(reason: String)
    }

    enum ProxyError: LocalizedError, Equatable {
        case invalidBrokerAddress
        case invalidPort
        case connectionClosed
        case connectionRejected(UInt8)
        case subscriptionRejected
        case connectionUnavailable

        var errorDescription: String? {
            switch self {
            case .invalidBrokerAddress:
                return String(localized: "The MQTT broker address is invalid.")
            case .invalidPort:
                return String(localized: "The MQTT broker port is invalid.")
            case .connectionClosed:
                return String(localized: "The MQTT broker closed the connection.")
            case .connectionRejected(let code):
                return String(localized: "The MQTT broker rejected the connection (code \(code)).")
            case .subscriptionRejected:
                return String(localized: "The MQTT broker rejected the topic subscription.")
            case .connectionUnavailable:
                return String(localized: "The MQTT connection is unavailable.")
            }
        }
    }

    typealias RadioMessageHandler = @Sendable (Meshtastic_MqttClientProxyMessage) async -> Void
    typealias StateHandler = @Sendable (State) async -> Void

    private var desiredConfiguration: Configuration?
    private var generation = UUID()
    private var connectionTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var transport: MQTTNetworkTransport?
    private var isConnected = false

    private var radioMessageHandler: RadioMessageHandler?
    private var stateHandler: StateHandler?
    private var radioMessageContinuations: [UUID: AsyncStream<Meshtastic_MqttClientProxyMessage>.Continuation] = [:]
    private var stateContinuations: [UUID: AsyncStream<State>.Continuation] = [:]

    private(set) var state: State = .stopped

    func setRadioMessageHandler(_ handler: RadioMessageHandler?) {
        radioMessageHandler = handler
    }

    func setStateHandler(_ handler: StateHandler?) {
        stateHandler = handler
    }

    func radioMessages() -> AsyncStream<Meshtastic_MqttClientProxyMessage> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: Meshtastic_MqttClientProxyMessage.self,
            bufferingPolicy: .bufferingNewest(100)
        )
        radioMessageContinuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeRadioMessageContinuation(id) }
        }
        return stream
    }

    func states() -> AsyncStream<State> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: State.self,
            bufferingPolicy: .bufferingNewest(30)
        )
        stateContinuations[id] = continuation
        continuation.yield(state)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeStateContinuation(id) }
        }
        return stream
    }

    /// Starts or restarts the proxy from the node's MQTT module configuration.
    /// Disabled configurations stop the service without opening a socket.
    func start(
        mqttConfig: Meshtastic_ModuleConfig.MQTTConfig,
        myNodeID: UInt32,
        appVersion: String? = nil
    ) async throws {
        guard mqttConfig.enabled, mqttConfig.proxyToClientEnabled else {
            await stop()
            return
        }
        let resolvedVersion = appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
        let configuration = try Configuration(
            mqttConfig: mqttConfig,
            myNodeID: myNodeID,
            appVersion: resolvedVersion
        )
        await start(configuration: configuration)
    }

    func start(configuration: Configuration) async {
        if desiredConfiguration == configuration, connectionTask != nil { return }
        await stop()

        desiredConfiguration = configuration
        let newGeneration = UUID()
        generation = newGeneration
        connectionTask = Task { [weak self] in
            await self?.connectionLoop(configuration: configuration, generation: newGeneration)
        }
    }

    func stop() async {
        desiredConfiguration = nil
        generation = UUID()
        isConnected = false
        pingTask?.cancel()
        pingTask = nil

        if let transport {
            try? await transport.send(MQTT311Codec.disconnect)
            transport.cancel()
        }
        self.transport = nil

        connectionTask?.cancel()
        connectionTask = nil
        await updateState(.stopped)
    }

    /// Forwards a radio-originated proxy message to the MQTT broker using QoS 0.
    func ingestRadioMessage(_ message: Meshtastic_MqttClientProxyMessage) async {
        guard isConnected, let transport, !message.topic.isEmpty else { return }

        let payload: Data
        switch message.payloadVariant {
        case .data(let data)?:
            payload = data
        case .text(let text)?:
            payload = Data(text.utf8)
        case nil:
            payload = Data()
        }

        do {
            let packet = try MQTT311Codec.publish(
                topic: message.topic,
                payload: payload,
                retained: message.retained
            )
            try await transport.send(packet)
        } catch {
            transport.cancel()
        }
    }

    // MARK: - Connection Lifecycle

    private func connectionLoop(configuration: Configuration, generation: UUID) async {
        while shouldRun(generation: generation) {
            do {
                try await runConnection(configuration: configuration, generation: generation)
            } catch is CancellationError {
                break
            } catch {
                isConnected = false
                transport?.cancel()
                transport = nil
                pingTask?.cancel()
                pingTask = nil

                guard shouldRun(generation: generation) else { break }
                await updateState(.waitingToReconnect(reason: error.localizedDescription))
                do {
                    try await Task.sleep(for: .seconds(configuration.reconnectDelaySeconds))
                } catch {
                    break
                }
            }
        }
    }

    private func runConnection(configuration: Configuration, generation: UUID) async throws {
        await updateState(.connecting(host: configuration.host, port: configuration.port))
        let transport = try MQTTNetworkTransport(configuration: configuration)
        self.transport = transport
        try await transport.start()
        try Task.checkCancellation()
        guard shouldRun(generation: generation) else { throw CancellationError() }

        let connectPacket = try MQTT311Codec.connect(
            clientID: configuration.clientID,
            username: configuration.username,
            password: configuration.password,
            keepAliveSeconds: configuration.keepAliveSeconds
        )
        try await transport.send(connectPacket)

        enum HandshakePhase {
            case waitingForConnAck
            case waitingForSubAck
            case connected
        }

        var phase = HandshakePhase.waitingForConnAck
        var decoder = MQTT311StreamDecoder()
        let subscribePacketID: UInt16 = 1

        while shouldRun(generation: generation) {
            try Task.checkCancellation()
            let chunk = try await transport.receive()
            if !chunk.data.isEmpty {
                let packets = try decoder.append(chunk.data)
                for packet in packets {
                    switch packet {
                    case .connAck(_, let returnCode) where phase == .waitingForConnAck:
                        guard returnCode == 0 else {
                            throw ProxyError.connectionRejected(returnCode)
                        }
                        let subscribe = try MQTT311Codec.subscribe(
                            topicFilter: configuration.subscriptionTopic,
                            packetID: subscribePacketID
                        )
                        try await transport.send(subscribe)
                        phase = .waitingForSubAck

                    case .subAck(let packetID, let returnCodes) where phase == .waitingForSubAck:
                        guard packetID == subscribePacketID,
                              !returnCodes.isEmpty,
                              !returnCodes.contains(0x80) else {
                            throw ProxyError.subscriptionRejected
                        }
                        phase = .connected
                        isConnected = true
                        await updateState(
                            .connected(
                                host: configuration.host,
                                port: configuration.port,
                                clientID: configuration.clientID
                            )
                        )
                        startPingLoop(
                            configuration: configuration,
                            generation: generation,
                            transport: transport
                        )

                    case .publish(let topic, let payload, let retained):
                        var message = Meshtastic_MqttClientProxyMessage()
                        message.topic = topic
                        message.data = payload
                        message.retained = retained
                        await emitRadioMessage(message)

                    default:
                        break
                    }
                }
            }
            if chunk.isComplete { throw ProxyError.connectionClosed }
        }
        throw CancellationError()
    }

    private func startPingLoop(
        configuration: Configuration,
        generation: UUID,
        transport: MQTTNetworkTransport
    ) {
        pingTask?.cancel()
        pingTask = Task { [weak self] in
            let interval = max(1, Int(configuration.keepAliveSeconds) / 2)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(interval))
                    guard let self,
                          await self.shouldRun(generation: generation),
                          await self.isCurrentTransport(transport) else {
                        break
                    }
                    try await transport.send(MQTT311Codec.pingRequest)
                } catch {
                    transport.cancel()
                    break
                }
            }
        }
    }

    private func shouldRun(generation: UUID) -> Bool {
        desiredConfiguration != nil && self.generation == generation && !Task.isCancelled
    }

    private func isCurrentTransport(_ transport: MQTTNetworkTransport) -> Bool {
        self.transport === transport && isConnected
    }

    // MARK: - Events

    private func emitRadioMessage(_ message: Meshtastic_MqttClientProxyMessage) async {
        radioMessageContinuations.values.forEach { $0.yield(message) }
        if let radioMessageHandler {
            await radioMessageHandler(message)
        }
    }

    private func updateState(_ state: State) async {
        guard self.state != state else { return }
        self.state = state
        stateContinuations.values.forEach { $0.yield(state) }
        if let stateHandler {
            await stateHandler(state)
        }
    }

    private func removeRadioMessageContinuation(_ id: UUID) {
        radioMessageContinuations.removeValue(forKey: id)
    }

    private func removeStateContinuation(_ id: UUID) {
        stateContinuations.removeValue(forKey: id)
    }
}

/// Parsed broker endpoint without any credentials.
struct MQTTBrokerEndpoint: Equatable, Sendable {
    let host: String
    let port: UInt16

    static func parse(_ address: String, useTLS: Bool) throws -> MQTTBrokerEndpoint {
        let defaultHost = "mqtt.meshtastic.org"
        let defaultPort: UInt16 = useTLS ? 8883 : 1883
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return MQTTBrokerEndpoint(host: defaultHost, port: defaultPort)
        }

        if trimmed.contains("://"),
           let components = URLComponents(string: trimmed),
           let host = components.host,
           !host.isEmpty {
            let port = try validatedPort(components.port, defaultPort: defaultPort)
            return MQTTBrokerEndpoint(host: host, port: port)
        }

        if trimmed.hasPrefix("[") {
            guard let closingBracket = trimmed.firstIndex(of: "]") else {
                throw MqttProxyService.ProxyError.invalidBrokerAddress
            }
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket])
            let suffix = trimmed[trimmed.index(after: closingBracket)...]
            if suffix.isEmpty {
                return MQTTBrokerEndpoint(host: host, port: defaultPort)
            }
            guard suffix.first == ":",
                  let port = UInt16(suffix.dropFirst()),
                  port > 0 else {
                throw MqttProxyService.ProxyError.invalidPort
            }
            return MQTTBrokerEndpoint(host: host, port: port)
        }

        if trimmed.filter({ $0 == ":" }).count == 1,
           let separator = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<separator])
            guard !host.isEmpty,
                  let port = UInt16(trimmed[trimmed.index(after: separator)...]),
                  port > 0 else {
                throw MqttProxyService.ProxyError.invalidBrokerAddress
            }
            return MQTTBrokerEndpoint(host: host, port: port)
        }

        return MQTTBrokerEndpoint(host: trimmed, port: defaultPort)
    }

    private static func validatedPort(_ port: Int?, defaultPort: UInt16) throws -> UInt16 {
        guard let port else { return defaultPort }
        guard let value = UInt16(exactly: port), value > 0 else {
            throw MqttProxyService.ProxyError.invalidPort
        }
        return value
    }
}

/// Thin async wrapper around NWConnection. The unchecked Sendable conformance is
/// safe because NWConnection supports concurrent send/cancel operations and all
/// higher-level lifecycle state remains isolated by `MqttProxyService`.
private final class MQTTNetworkTransport: @unchecked Sendable {
    struct ReceiveChunk: Sendable {
        let data: Data
        let isComplete: Bool
    }

    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.marcelwolf.MeshHessen.mqtt-proxy")

    init(configuration: MqttProxyService.Configuration) throws {
        guard let port = NWEndpoint.Port(rawValue: configuration.port) else {
            throw MqttProxyService.ProxyError.invalidPort
        }
        let parameters: NWParameters
        if configuration.useTLS {
            parameters = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
        } else {
            parameters = .tcp
        }
        connection = NWConnection(
            host: NWEndpoint.Host(configuration.host),
            port: port,
            using: parameters
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let gate = MQTTConnectionStartGate(continuation: continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    gate.resume()
                case .failed(let error):
                    gate.resume(throwing: error)
                case .cancelled:
                    gate.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    func receive() async throws -> ReceiveChunk {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: ReceiveChunk(data: data ?? Data(), isComplete: isComplete)
                    )
                }
            }
        }
    }

    func cancel() {
        connection.cancel()
    }
}

private final class MQTTConnectionStartGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?

    init(continuation: CheckedContinuation<Void, Error>) {
        self.continuation = continuation
    }

    func resume() {
        takeContinuation()?.resume()
    }

    func resume(throwing error: Error) {
        takeContinuation()?.resume(throwing: error)
    }

    private func takeContinuation() -> CheckedContinuation<Void, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let value = continuation
        continuation = nil
        return value
    }
}
