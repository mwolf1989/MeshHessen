@preconcurrency import CoreBluetooth
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/BleGattLink.cs (BleScanner, BleNotificationQueue, BleGattLink)

// MARK: - Scan criteria

/// What a device in OTA-loader / bootloader mode looks like. CoreBluetooth exposes no MAC address, so the
/// loader is recognised by advertised service UUIDs and/or name, or by the identifier of the former mesh
/// peripheral when the loader keeps its address. All parts are configurable for field testing.
struct BleScanCriteria: Equatable, Sendable {
    /// Any of these advertised services matches.
    var services: Set<GattUUID>
    /// Identifiers that match on sight (e.g. the mesh peripheral the device was connected as).
    var peripheralIDs: Set<UUID> = []
    /// Case-insensitive substrings of the advertised name that match.
    var nameFragments: [String] = []

    func matches(id: UUID, name: String?, services advertised: Set<GattUUID>) -> Bool {
        if peripheralIDs.contains(id) { return true }
        if !services.isDisjoint(with: advertised) { return true }
        guard let name, !name.isEmpty else { return false }
        return nameFragments.contains { !$0.isEmpty && name.localizedCaseInsensitiveContains($0) }
    }

    /// Best candidate: a known identifier first, then the strongest signal.
    func best(of hits: [DfuScanHit]) -> DfuScanHit? {
        hits.max { lhs, rhs in
            let lhsKnown = peripheralIDs.contains(lhs.id)
            let rhsKnown = peripheralIDs.contains(rhs.id)
            if lhsKnown != rhsKnown { return rhsKnown }
            return lhs.rssi < rhs.rssi
        }
    }

    /// The ESP32 Unified OTA loader.
    static func esp32Loader(previous id: UUID?) -> BleScanCriteria {
        BleScanCriteria(services: [BleOtaTransport.serviceUUID], peripheralIDs: id.map { [$0] } ?? [])
    }

    /// A Nordic bootloader (Secure FE59 or Legacy 1530). Adafruit names it "AdaDFU", Nordic "DfuTarg".
    static func nordicBootloader(previous id: UUID?) -> BleScanCriteria {
        BleScanCriteria(
            services: [SecureDfuUuids.service, LegacyDfuUuids.service],
            peripheralIDs: id.map { [$0] } ?? [],
            nameFragments: ["dfu"]
        )
    }
}

// MARK: - CoreBluetooth link

/// CoreBluetooth GATT client for the OTA/DFU transports: its **own** `CBCentralManager` on a private
/// queue (the mesh link's central is never reused), scan, connect, discovery, subscriptions, paced
/// writes. Every delegate callback is bridged with a continuation and every wait has a timeout.
/// Used only after the mesh link was released (or, in recovery mode, without one).
final class BleGattLink: NSObject, DfuGattLink, @unchecked Sendable {
    static let powerOnTimeout: Duration = .seconds(5)
    static let connectTimeout: Duration = .seconds(15)
    static let disconnectTimeout: Duration = .seconds(3)
    static let subscribeTimeout: Duration = .seconds(10)
    /// Extra listening time after the first non-preferred match, so a nearer or known device can win.
    static let scanSettle: Duration = .milliseconds(1500)

    private let queue = DispatchQueue(label: "dev.marcelwolf.MeshHessen.firmware-ble", qos: .userInitiated)
    private var central: CBCentralManager!
    private let stateLock = NSLock()

    // Touched only on `queue`.
    private var peripheral: CBPeripheral?
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var characteristics: [GattUUID: CBCharacteristic] = [:]
    private var notificationQueues: [GattUUID: GattNotificationQueue] = [:]
    private var discoveryService: GattUUID?
    private var discoveryCharacteristics: [GattUUID] = []
    private var subscribing: GattUUID?
    private var reading: GattUUID?
    private var pendingNoResponse: (data: Data, characteristic: CBCharacteristic)?
    private var scanCriteria: BleScanCriteria?
    private var scanSeen: [UUID: (name: String?, services: Set<GattUUID>, rssi: Int)] = [:]
    private var scanCandidates: [UUID: DfuScanHit] = [:]
    private var scanSettling = false

    // Guarded by `stateLock`.
    private var disconnectedFlag = false
    private var connectedFlag = false

    private let powerSlot = OperationSlot<Void>()
    private let connectSlot = OperationSlot<Void>()
    private let disconnectSlot = OperationSlot<Void>()
    private let discoverSlot = OperationSlot<Set<GattUUID>?>()
    private let servicesSlot = OperationSlot<[GattUUID]>()
    private let subscribeSlot = OperationSlot<Void>()
    private let writeSlot = OperationSlot<Void>()
    private let readSlot = OperationSlot<Data?>()
    private let scanSlot = OperationSlot<DfuScanHit?>()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    // MARK: DfuGattLink

    var maxWriteLength: Int {
        queue.sync {
            guard let peripheral else { return 20 }
            return max(20, peripheral.maximumWriteValueLength(for: .withoutResponse))
        }
    }

    var isDisconnected: Bool { stateLock.withLock { disconnectedFlag } }

    // MARK: Scan

    /// Up to `attempts` scans of `timeout` each, `retryDelay` apart. nil when nothing matched.
    func scan(
        criteria: BleScanCriteria,
        attempts: Int,
        timeout: Duration,
        retryDelay: Duration,
        tag: String
    ) async throws -> DfuScanHit? {
        for attempt in 1...max(1, attempts) {
            AppLogger.shared.log("[\(tag)] Scan attempt \(attempt)/\(attempts)")
            if let hit = try await scan(criteria: criteria, timeout: timeout) {
                AppLogger.shared.log("[\(tag)] Found \(hit.name ?? "?") (\(hit.id)) rssi=\(hit.rssi) services=[\(hit.advertisedServices.map(\.value).sorted().joined(separator: ","))]")
                return hit
            }
            if attempt < attempts { try await Task.sleep(for: retryDelay) }
        }
        return nil
    }

    /// One scan; nil when the timeout elapsed without a match.
    func scan(criteria: BleScanCriteria, timeout: Duration) async throws -> DfuScanHit? {
        try await waitPoweredOn()
        do {
            return try await perform(scanSlot, timeout: timeout, what: "scan") { [self] in
                scanCriteria = criteria
                scanSeen = [:]
                scanCandidates = [:]
                scanSettling = false
                central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
        } catch FirmwareBleError.timeout {
            // A match found during the settle window still counts.
            return queue.sync {
                let hit = scanCriteria?.best(of: Array(scanCandidates.values))
                finishScan()
                return hit
            }
        } catch {
            queue.sync { finishScan() }
            throw error
        }
    }

    /// Runs on `queue`.
    private func finishScan() {
        if central.isScanning { central.stopScan() }
        AppLogger.shared.log("[BLE fw] Scan ended, \(scanSeen.count) devices seen, \(scanCandidates.count) matching")
        scanCriteria = nil
        scanSettling = false
    }

    /// Runs on `queue`.
    private func resolveScan(with hit: DfuScanHit?) {
        finishScan()
        if scanCandidates.count > 1 {
            AppLogger.shared.log("[BLE fw] Several matching devices: \(scanCandidates.values.map { "\($0.name ?? "?") \($0.rssi) dBm" }.joined(separator: ", ")) — chose \(hit?.name ?? "?")")
        }
        scanSlot.resume(.success(hit))
    }

    // MARK: Connect

    /// Connects to a peripheral seen by any scan of this app (CoreBluetooth identifiers are app-wide);
    /// scans briefly for it when the system does not know it.
    func connect(to id: UUID, timeout: Duration = BleGattLink.connectTimeout) async throws {
        try await waitPoweredOn()
        let known = queue.sync { knownPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first }
        if known == nil {
            let criteria = BleScanCriteria(services: [], peripheralIDs: [id])
            guard try await scan(criteria: criteria, timeout: .seconds(10)) != nil else {
                throw FirmwareBleError.peripheralNotFound
            }
        }
        stateLock.withLock { disconnectedFlag = false }
        do {
            try await perform(connectSlot, timeout: timeout, what: "connect") { [self] in
                guard let target = knownPeripherals[id] ?? central.retrievePeripherals(withIdentifiers: [id]).first else {
                    connectSlot.resume(.failure(FirmwareBleError.peripheralNotFound))
                    return
                }
                peripheral = target
                target.delegate = self
                characteristics = [:]
                central.connect(target, options: nil)
            }
        } catch {
            await disconnect()
            throw error
        }
        stateLock.withLock { connectedFlag = true }
        AppLogger.shared.log("[BLE fw] Connected to \(queue.sync { peripheral?.name } ?? id.uuidString), write payload \(maxWriteLength) bytes")
    }

    // MARK: Discovery

    func discover(service: GattUUID, characteristics wanted: [GattUUID], timeout: Duration) async throws -> Set<GattUUID>? {
        try requireConnected()
        return try await perform(discoverSlot, timeout: timeout, what: "discover \(service)") { [self] in
            guard let peripheral else {
                discoverSlot.resume(.failure(FirmwareBleError.disconnected))
                return
            }
            discoveryService = service
            discoveryCharacteristics = wanted
            peripheral.discoverServices([CBUUID(string: service.value)])
        }
    }

    func listServices(timeout: Duration) async throws -> [GattUUID] {
        try requireConnected()
        return try await perform(servicesSlot, timeout: timeout, what: "list services") { [self] in
            guard let peripheral else {
                servicesSlot.resume(.failure(FirmwareBleError.disconnected))
                return
            }
            discoveryService = nil
            peripheral.discoverServices(nil)
        }
    }

    // MARK: Notifications

    /// CoreBluetooth enables indications or notifications according to the characteristic's properties,
    /// so `indicate` only documents the caller's intent.
    func subscribe(_ characteristic: GattUUID, indicate: Bool) async throws {
        try requireConnected()
        try await perform(subscribeSlot, timeout: Self.subscribeTimeout, what: "subscribe \(characteristic)") { [self] in
            guard let peripheral, let target = characteristics[characteristic] else {
                subscribeSlot.resume(.failure(FirmwareBleError.characteristicMissing(characteristic.value)))
                return
            }
            guard target.properties.contains(.notify) || target.properties.contains(.indicate) else {
                subscribeSlot.resume(.failure(FirmwareBleError.operationFailed("\(characteristic) cannot notify")))
                return
            }
            if notificationQueues[characteristic] == nil { notificationQueues[characteristic] = GattNotificationQueue() }
            subscribing = characteristic
            peripheral.setNotifyValue(true, for: target)
        }
    }

    func receive(from characteristic: GattUUID, timeout: Duration) async throws -> Data? {
        guard let notifications = queue.sync(execute: { notificationQueues[characteristic] }) else {
            throw FirmwareBleError.operationFailed("not subscribed to \(characteristic)")
        }
        return try await notifications.next(timeout: timeout)
    }

    // MARK: Write / read

    func write(_ data: Data, to characteristic: GattUUID, withResponse: Bool, timeout: Duration) async throws {
        try requireConnected()
        do {
            try await performWrite(data, to: characteristic, withResponse: withResponse, timeout: timeout)
        } catch {
            // A paced chunk that timed out or was cancelled must never be sent later.
            queue.sync { pendingNoResponse = nil }
            throw error
        }
    }

    private func performWrite(_ data: Data, to characteristic: GattUUID, withResponse: Bool, timeout: Duration) async throws {
        try await perform(writeSlot, timeout: timeout, what: "write \(characteristic)") { [self] in
            guard let peripheral, let target = characteristics[characteristic] else {
                writeSlot.resume(.failure(FirmwareBleError.characteristicMissing(characteristic.value)))
                return
            }
            let canWriteWithoutResponse = target.properties.contains(.writeWithoutResponse)
            if withResponse || !canWriteWithoutResponse {
                if !withResponse {
                    AppLogger.shared.log("[BLE fw] \(characteristic) has no write-without-response; writing with response")
                }
                peripheral.writeValue(data, for: target, type: .withResponse)
            } else if peripheral.canSendWriteWithoutResponse {
                peripheral.writeValue(data, for: target, type: .withoutResponse)
                writeSlot.resume(.success(()))
            } else {
                // Paced: sent from `peripheralIsReady(toSendWriteWithoutResponse:)`.
                pendingNoResponse = (data, target)
            }
        }
    }

    func read(_ characteristic: GattUUID, timeout: Duration) async throws -> Data? {
        try requireConnected()
        do {
            return try await perform(readSlot, timeout: timeout, what: "read \(characteristic)") { [self] in
                guard let peripheral, let target = characteristics[characteristic] else {
                    readSlot.resume(.success(nil))
                    return
                }
                reading = characteristic
                peripheral.readValue(for: target)
            }
        } catch is CancellationError {
            queue.sync { reading = nil }
            throw CancellationError()
        } catch FirmwareBleError.disconnected {
            throw FirmwareBleError.disconnected
        } catch {
            queue.sync { reading = nil }
            AppLogger.shared.log("[BLE fw] Read \(characteristic) failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Disconnect

    func disconnect() async {
        let wasConnected = stateLock.withLock { connectedFlag && !disconnectedFlag }
        if wasConnected {
            _ = try? await perform(disconnectSlot, timeout: Self.disconnectTimeout, what: "disconnect") { [self] in
                if central.isScanning { central.stopScan() }
                if let peripheral { central.cancelPeripheralConnection(peripheral) } else { disconnectSlot.resume(.success(())) }
            }
        }
        queue.sync {
            if central.isScanning { central.stopScan() }
            if let peripheral { central.cancelPeripheralConnection(peripheral) }
            markDisconnected()
        }
    }

    // MARK: Helpers

    private func requireConnected() throws {
        let state = stateLock.withLock { (connectedFlag, disconnectedFlag) }
        guard state.0, !state.1 else { throw FirmwareBleError.disconnected }
    }

    private func waitPoweredOn() async throws {
        let state = queue.sync { central.state }
        if state == .poweredOn { return }
        if let reason = Self.unavailableReason(state) { throw FirmwareBleError.bluetoothUnavailable(reason) }
        try await perform(powerSlot, timeout: Self.powerOnTimeout, what: "Bluetooth power-on") { [self] in
            if central.state == .poweredOn { powerSlot.resume(.success(())) }
        }
    }

    private static func unavailableReason(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOff: "powered off"
        case .unauthorized: "not authorised"
        case .unsupported: "unsupported"
        default: nil
        }
    }

    /// Stores the continuation in `slot`, runs `start` on the Bluetooth queue and waits for the delegate
    /// callback, the timeout (`FirmwareBleError.timeout`) or task cancellation, whichever comes first.
    private func perform<T>(
        _ slot: OperationSlot<T>,
        timeout: Duration,
        what: String,
        start: @escaping () -> Void
    ) async throws -> T {
        let timer = Task { [slot] in
            try? await Task.sleep(for: timeout)
            if !Task.isCancelled { slot.resume(.failure(FirmwareBleError.timeout(what))) }
        }
        defer { timer.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
                slot.store(continuation)
                if Task.isCancelled {
                    slot.resume(.failure(CancellationError()))
                    return
                }
                queue.async(execute: start)
            }
        } onCancel: {
            slot.resume(.failure(CancellationError()))
        }
    }

    /// Runs on `queue`: closes notification queues and fails every pending operation.
    private func markDisconnected() {
        stateLock.withLock {
            disconnectedFlag = true
            connectedFlag = false
        }
        notificationQueues.values.forEach { $0.close() }
        pendingNoResponse = nil
        let failure = FirmwareBleError.disconnected
        connectSlot.resume(.failure(failure))
        discoverSlot.resume(.failure(failure))
        servicesSlot.resume(.failure(failure))
        subscribeSlot.resume(.failure(failure))
        writeSlot.resume(.failure(failure))
        readSlot.resume(.failure(failure))
        disconnectSlot.resume(.success(()))
    }
}

// MARK: - Factories

extension BleGattLink {
    /// A fresh link connected to `id`.
    static func open(id: UUID) async throws -> BleGattLink {
        let link = BleGattLink()
        try await link.connect(to: id)
        return link
    }

    /// Scans for `criteria` and connects to the match; throws `notFound` when nothing matched.
    static func scanAndConnect(
        criteria: BleScanCriteria,
        attempts: Int,
        timeout: Duration,
        retryDelay: Duration,
        tag: String,
        notFound: Error
    ) async throws -> BleGattLink {
        let link = BleGattLink()
        guard let hit = try await link.scan(criteria: criteria, attempts: attempts, timeout: timeout, retryDelay: retryDelay, tag: tag) else {
            throw notFound
        }
        try await link.connect(to: hit.id)
        return link
    }
}

// MARK: - CBCentralManagerDelegate

extension BleGattLink: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        AppLogger.shared.log("[BLE fw] Central state \(central.state.rawValue)")
        if central.state == .poweredOn {
            powerSlot.resume(.success(()))
            return
        }
        if let reason = Self.unavailableReason(central.state) {
            powerSlot.resume(.failure(FirmwareBleError.bluetoothUnavailable(reason)))
            scanSlot.resume(.failure(FirmwareBleError.bluetoothUnavailable(reason)))
        }
        if peripheral != nil, central.state != .poweredOn, central.state != .unknown {
            markDisconnected()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        knownPeripherals[peripheral.identifier] = peripheral
        guard let criteria = scanCriteria else { return }

        var entry = scanSeen[peripheral.identifier] ?? (name: nil, services: [], rssi: RSSI.intValue)
        if let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String, !local.isEmpty {
            entry.name = local
        } else if entry.name == nil {
            entry.name = peripheral.name
        }
        let advertised = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        entry.services.formUnion(advertised.map { GattUUID($0.uuidString) })
        if RSSI.intValue != 127 { entry.rssi = RSSI.intValue }
        scanSeen[peripheral.identifier] = entry

        guard criteria.matches(id: peripheral.identifier, name: entry.name, services: entry.services) else { return }
        let hit = DfuScanHit(id: peripheral.identifier, name: entry.name, advertisedServices: entry.services, rssi: entry.rssi)
        scanCandidates[hit.id] = hit
        if criteria.peripheralIDs.contains(hit.id) {
            resolveScan(with: hit)
        } else if !scanSettling {
            scanSettling = true
            let settle = Self.scanSettle
            queue.asyncAfter(deadline: .now() + Double(settle.components.seconds) + Double(settle.components.attoseconds) / 1e18) { [weak self] in
                guard let self, self.scanSettling else { return }
                self.resolveScan(with: criteria.best(of: Array(self.scanCandidates.values)))
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral === self.peripheral else { return }
        connectSlot.resume(.success(()))
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        connectSlot.resume(.failure(FirmwareBleError.connectFailed(error?.localizedDescription ?? "unknown")))
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        guard peripheral === self.peripheral else { return }
        AppLogger.shared.log("[BLE fw] Disconnected from \(peripheral.name ?? peripheral.identifier.uuidString)\(error.map { ": \($0.localizedDescription)" } ?? "")")
        markDisconnected()
    }
}

// MARK: - CBPeripheralDelegate

extension BleGattLink: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services ?? []
        guard let wanted = discoveryService else {
            if let error {
                servicesSlot.resume(.failure(FirmwareBleError.operationFailed(error.localizedDescription)))
            } else {
                servicesSlot.resume(.success(services.map { GattUUID($0.uuid.uuidString) }))
            }
            return
        }
        if let error {
            discoverSlot.resume(.failure(FirmwareBleError.operationFailed(error.localizedDescription)))
            return
        }
        guard let service = services.first(where: { GattUUID($0.uuid.uuidString) == wanted }) else {
            discoverSlot.resume(.success(nil))
            return
        }
        peripheral.discoverCharacteristics(discoveryCharacteristics.map { CBUUID(string: $0.value) }, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let wanted = discoveryService, GattUUID(service.uuid.uuidString) == wanted else { return }
        if let error {
            discoverSlot.resume(.failure(FirmwareBleError.operationFailed(error.localizedDescription)))
            return
        }
        var found = Set<GattUUID>()
        for characteristic in service.characteristics ?? [] {
            let id = GattUUID(characteristic.uuid.uuidString)
            characteristics[id] = characteristic
            found.insert(id)
        }
        discoverSlot.resume(.success(found.intersection(discoveryCharacteristics)))
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let id = GattUUID(characteristic.uuid.uuidString)
        guard id == subscribing else { return }
        subscribing = nil
        if let error {
            subscribeSlot.resume(.failure(FirmwareBleError.operationFailed(error.localizedDescription)))
        } else {
            subscribeSlot.resume(.success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = GattUUID(characteristic.uuid.uuidString)
        if id == reading {
            reading = nil
            readSlot.resume(error == nil ? .success(characteristic.value) : .success(nil))
            return
        }
        guard error == nil, let value = characteristic.value else { return }
        notificationQueues[id]?.push(value)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            writeSlot.resume(.failure(FirmwareBleError.operationFailed(error.localizedDescription)))
        } else {
            writeSlot.resume(.success(()))
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard let pending = pendingNoResponse, peripheral.canSendWriteWithoutResponse else { return }
        pendingNoResponse = nil
        peripheral.writeValue(pending.data, for: pending.characteristic, type: .withoutResponse)
        writeSlot.resume(.success(()))
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        AppLogger.shared.log("[BLE fw] Peripheral reported changed services (\(invalidatedServices.count))")
    }
}

// MARK: - Continuation slot

/// One pending continuation; resuming is idempotent (the first result wins), so callback, timeout,
/// cancellation and disconnect can race safely.
private final class OperationSlot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func store(_ newContinuation: CheckedContinuation<T, Error>) {
        let previous: CheckedContinuation<T, Error>? = lock.withLock {
            let old = continuation
            continuation = newContinuation
            return old
        }
        previous?.resume(throwing: FirmwareBleError.operationFailed("superseded"))
    }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            let current = continuation
            continuation = nil
            return current
        }
        pending?.resume(with: result)
    }
}
