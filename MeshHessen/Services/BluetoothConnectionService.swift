@preconcurrency import CoreBluetooth
import Foundation

/// BLE connection to a Meshtastic node via CoreBluetooth
/// Uses FromNum notifications to drain queued packets, with polling only as a fallback.
final class BluetoothConnectionService: NSObject, ConnectionService, @unchecked Sendable {
    let type: ConnectionType = .bluetooth

    private let callbackLock = NSLock()
    private var dataReceivedHandler: ((Data) -> Void)?
    private var connectionStateHandler: ((Bool) -> Void)?
    private var peripheralDiscoveredHandler: ((CBPeripheral, NSNumber) -> Void)?

    var onDataReceived: ((Data) -> Void)? {
        get { callbackLock.withLock { dataReceivedHandler } }
        set { callbackLock.withLock { dataReceivedHandler = newValue } }
    }

    var onConnectionStateChanged: ((Bool) -> Void)? {
        get { callbackLock.withLock { connectionStateHandler } }
        set { callbackLock.withLock { connectionStateHandler = newValue } }
    }

    private let stateLock = NSLock()
    private var connected = false
    var isConnected: Bool {
        stateLock.withLock { connected }
    }

    // Meshtastic BLE service / characteristic UUIDs
    static let serviceUUID   = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID   = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumUUID   = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

    /// CoreBluetooth requires ordered delegate callbacks and works most reliably
    /// when every GATT operation is submitted on the same serial queue.
    private let bluetoothQueue = DispatchQueue(label: "dev.marcelwolf.MeshHessen.bluetooth", qos: .userInitiated)
    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var toRadioChar: CBCharacteristic?
    private var fromRadioChar: CBCharacteristic?
    private var fromNumChar: CBCharacteristic?

    private var connectContinuation: CheckedContinuation<Void, Error>?
    /// Protects `connectContinuation` from simultaneous access by the BLE delegate queue and MainActor
    private let continuationLock = NSLock()
    private var connectTimeoutTask: Task<Void, Never>?
    private var targetDeviceName: String = ""
    private var targetDeviceAddress: String = ""
    private var pollingTask: Task<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Error>?
    private var readContinuation: CheckedContinuation<Data, Error>?
    private let operationTurnLock = NSLock()
    private var operationTurnHeld = false
    private var operationTurnWaiters: [CheckedContinuation<Void, Error>] = []
    private let drainLock = NSLock()
    private var needsDrain = false
    private var isDraining = false

    // Discovered peripherals during scan (keyed by UUID for fast lookup)
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var discoveredPeripherals: [(peripheral: CBPeripheral, rssi: NSNumber)] = []
    var onPeripheralDiscovered: ((CBPeripheral, NSNumber) -> Void)? {
        get { callbackLock.withLock { peripheralDiscoveredHandler } }
        set { callbackLock.withLock { peripheralDiscoveredHandler = newValue } }
    }

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: bluetoothQueue)
    }

    // MARK: - Thread-safe continuation helpers

    /// Atomically stores a new connect continuation under the lock.
    private func storeConnectContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.withLock { connectContinuation = cont }
    }

    /// Atomically extracts and nils the connect continuation so it can only be resumed once.
    private func takeConnectContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.withLock {
            let c = connectContinuation
            connectContinuation = nil
            return c
        }
    }

    /// Thread-safe check whether a connect continuation is pending.
    private var hasConnectContinuation: Bool {
        continuationLock.withLock { connectContinuation != nil }
    }

    /// Atomically stores a new write continuation under the lock.
    private func storeWriteContinuation(_ cont: CheckedContinuation<Void, Error>) {
        continuationLock.withLock { writeContinuation = cont }
    }

    /// Atomically extracts and nils the write continuation so it can only be resumed once.
    private func takeWriteContinuation() -> CheckedContinuation<Void, Error>? {
        continuationLock.withLock {
            let c = writeContinuation
            writeContinuation = nil
            return c
        }
    }

    private func storeReadContinuation(_ cont: CheckedContinuation<Data, Error>) {
        continuationLock.withLock { readContinuation = cont }
    }

    private func takeReadContinuation() -> CheckedContinuation<Data, Error>? {
        continuationLock.withLock {
            let c = readContinuation
            readContinuation = nil
            return c
        }
    }

    /// Ensures only one GATT read or write is in flight at a time. Writes queued
    /// while a drain is active get the next turn after the current packet read.
    private func waitForOperationTurn() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumeNow = false
            operationTurnLock.withLock {
                if !operationTurnHeld {
                    operationTurnHeld = true
                    resumeNow = true
                } else {
                    operationTurnWaiters.append(cont)
                }
            }
            if resumeNow {
                cont.resume()
            }
        }
    }

    private func releaseOperationTurn() {
        var next: CheckedContinuation<Void, Error>?
        operationTurnLock.withLock {
            if operationTurnWaiters.isEmpty {
                operationTurnHeld = false
            } else {
                next = operationTurnWaiters.removeFirst()
            }
        }
        next?.resume()
    }

    private func cancelOperationWaiters() {
        let waiters = operationTurnLock.withLock {
            operationTurnHeld = false
            let pending = operationTurnWaiters
            operationTurnWaiters.removeAll()
            return pending
        }
        waiters.forEach { $0.resume(throwing: ConnectionError.cancelled) }
    }

    private func setConnected(_ value: Bool) {
        stateLock.withLock { connected = value }
    }

    private func requestDrain() {
        var shouldStart = false
        drainLock.withLock {
            needsDrain = true
            if !isDraining {
                isDraining = true
                shouldStart = true
            }
        }

        guard shouldStart else { return }
        Task { await runDrainLoop() }
    }

    private func resetDrainState() {
        drainLock.withLock {
            needsDrain = false
            isDraining = false
        }
    }

    private func runDrainLoop() async {
        while true {
            drainLock.withLock {
                needsDrain = false
            }

            await drainFromRadio()

            let shouldContinue = drainLock.withLock { needsDrain }
            if !shouldContinue {
                break
            }
        }

        var shouldRestart = false
        drainLock.withLock {
            isDraining = false
            if needsDrain, isConnected {
                isDraining = true
                shouldRestart = true
            }
        }

        if shouldRestart {
            Task { await runDrainLoop() }
        }
    }

    private func writeWithResponse(_ data: Data, to characteristic: CBCharacteristic, on peripheral: CBPeripheral) async throws {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self else { return }
            if let cont = self.takeWriteContinuation() {
                AppLogger.shared.log("[BLE] Write timed out after 10s", debug: true)
                cont.resume(throwing: ConnectionError.timeout)
            }
        }
        defer { timeoutTask.cancel() }

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            bluetoothQueue.async { [weak self] in
                guard let self,
                      self.isConnected,
                      self.peripheral === peripheral,
                      self.toRadioChar === characteristic else {
                    cont.resume(throwing: ConnectionError.notConnected)
                    return
                }
                self.storeWriteContinuation(cont)
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }

    private func readWithResponse(from characteristic: CBCharacteristic, on peripheral: CBPeripheral) async throws -> Data {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if let cont = self.takeReadContinuation() {
                AppLogger.shared.log("[BLE] Read timed out after 5s", debug: true)
                cont.resume(throwing: ConnectionError.timeout)
            }
        }
        defer { timeoutTask.cancel() }

        return try await withCheckedThrowingContinuation { cont in
            bluetoothQueue.async { [weak self] in
                guard let self,
                      self.isConnected,
                      self.peripheral === peripheral,
                      self.fromRadioChar === characteristic else {
                    cont.resume(throwing: ConnectionError.notConnected)
                    return
                }
                self.storeReadContinuation(cont)
                peripheral.readValue(for: characteristic)
            }
        }
    }

    func connect(parameters: ConnectionParameters) async throws {
        guard case .bluetooth(let address, let name) = parameters else {
            AppLogger.shared.log("[BLE] Invalid connection parameters", debug: true)
            throw ConnectionError.invalidParameters
        }
        AppLogger.shared.log("[BLE] Connecting to device: \(name) (address: \(address))", debug: SettingsService.shared.debugBluetooth)

        return try await withCheckedThrowingContinuation { cont in
            bluetoothQueue.async { [weak self] in
                guard let self else {
                    cont.resume(throwing: ConnectionError.cancelled)
                    return
                }

                self.targetDeviceAddress = address
                self.targetDeviceName = name
                self.storeConnectContinuation(cont)

                // If we already know this peripheral (e.g. from a prior scan), connect directly.
                if let uuid = UUID(uuidString: address), let known = self.knownPeripherals[uuid] {
                    AppLogger.shared.log("[BLE] Peripheral already known – connecting directly to \(known.name ?? uuid.uuidString)", debug: SettingsService.shared.debugBluetooth)
                    self.centralManager.stopScan()
                    self.peripheral = known
                    known.delegate = self
                    self.centralManager.connect(known, options: nil)
                } else {
                    AppLogger.shared.log("[BLE] Peripheral unknown – starting scan (20 s timeout)", debug: SettingsService.shared.debugBluetooth)
                    self.centralManager.scanForPeripherals(
                        withServices: [BluetoothConnectionService.serviceUUID],
                        options: nil
                    )
                    AppLogger.shared.log("[BLE] Scanning for peripherals...", debug: SettingsService.shared.debugBluetooth)
                }

                self.startConnectTimeout()
            }
        }
    }

    func disconnect() {
        AppLogger.shared.log("[BLE] Disconnecting...", debug: SettingsService.shared.debugBluetooth)
        cancelOperationWaiters()
        setConnected(false)

        bluetoothQueue.async { [weak self] in
            guard let self else { return }
            // Cancel pending continuations on the delegate queue so they cannot
            // race with a late CoreBluetooth callback.
            self.connectTimeoutTask?.cancel()
            self.connectTimeoutTask = nil
            self.pollingTask?.cancel()
            self.pollingTask = nil
            self.takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
            self.takeWriteContinuation()?.resume(throwing: ConnectionError.cancelled)
            self.takeReadContinuation()?.resume(throwing: ConnectionError.cancelled)
            self.resetDrainState()
            self.centralManager.stopScan()
            if let peripheral = self.peripheral {
                self.centralManager.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.toRadioChar = nil
            self.fromRadioChar = nil
            self.fromNumChar = nil
            self.onConnectionStateChanged?(false)
            AppLogger.shared.log("[BLE] Disconnected", debug: SettingsService.shared.debugBluetooth)
        }
    }

    func write(_ data: Data) async throws {
        try await waitForOperationTurn()
        defer { releaseOperationTurn() }

        guard let p = peripheral, let char = toRadioChar, isConnected else {
            AppLogger.shared.log("[BLE] Write failed: not connected", debug: SettingsService.shared.debugBluetooth)
            throw ConnectionError.notConnected
        }

        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse

        AppLogger.shared.log("[BLE] Writing \(data.count) bytes (type: \(writeType == .withoutResponse ? "withoutResponse" : "withResponse"))", debug: SettingsService.shared.debugBluetooth)

        if writeType == .withoutResponse {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                bluetoothQueue.async { [weak self] in
                    guard let self,
                          self.isConnected,
                          self.peripheral === p,
                          self.toRadioChar === char else {
                        cont.resume(throwing: ConnectionError.notConnected)
                        return
                    }
                    p.writeValue(data, for: char, type: .withoutResponse)
                    cont.resume()
                }
            }
            requestDrain()
        } else {
            try await writeWithResponse(data, to: char, on: p)
        }
    }

    func startScanning() {
        bluetoothQueue.async { [weak self] in
            guard let self else { return }
            self.discoveredPeripherals.removeAll()
            self.knownPeripherals.removeAll()
            AppLogger.shared.log("[BLE] Started scanning for peripherals", debug: SettingsService.shared.debugBluetooth)
            self.centralManager.scanForPeripherals(
                withServices: [BluetoothConnectionService.serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )
        }
    }

    func stopScanning() {
        bluetoothQueue.async { [weak self] in
            guard let self else { return }
            self.centralManager.stopScan()
            AppLogger.shared.log("[BLE] Stopped scanning. Found \(self.discoveredPeripherals.count) peripherals", debug: SettingsService.shared.debugBluetooth)
        }
    }

    // MARK: - Private

    private func startConnectTimeout() {
        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            self.bluetoothQueue.async {
                self.centralManager.stopScan()
                self.connectTimeoutTask = nil
                if let cont = self.takeConnectContinuation() {
                    AppLogger.shared.log("[BLE] Connect timed out", debug: true)
                    cont.resume(throwing: ConnectionError.timeout)
                }
            }
        }
    }

    private func startPolling() {
        AppLogger.shared.log("[BLE] Starting polling fallback (250ms interval)", debug: SettingsService.shared.debugBluetooth)
        pollingTask = Task { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                guard let self, self.isConnected else {
                    AppLogger.shared.log("[BLE] Polling stopped: not connected", debug: SettingsService.shared.debugBluetooth)
                    break
                }
                self.requestDrain()
                try? await Task.sleep(for: .milliseconds(250))
                iteration += 1
                if iteration % 20 == 0 { // Log every ~5 seconds
                    AppLogger.shared.log("[BLE] Polling active (iteration \(iteration))", debug: SettingsService.shared.debugBluetooth)
                }
            }
            AppLogger.shared.log("[BLE] Polling task ended (cancelled: \(Task.isCancelled))", debug: SettingsService.shared.debugBluetooth)
        }
    }

    /// Triggers an immediate drain outside the polling loop (e.g. on fromNum notification).
    private func triggerImmediateDrain() {
        requestDrain()
    }

    private func drainFromRadio() async {
        while isConnected {
            do {
                try await waitForOperationTurn()
            } catch {
                return
            }

            guard let peripheral, let fromRadioChar, isConnected else {
                releaseOperationTurn()
                return
            }

            let data: Data
            do {
                data = try await readWithResponse(from: fromRadioChar, on: peripheral)
            } catch {
                releaseOperationTurn()
                guard isConnected else { return }
                AppLogger.shared.log("[BLE] Drain read failed: \(error.localizedDescription)", debug: true)
                return
            }

            releaseOperationTurn()

            guard !data.isEmpty else { return }
            AppLogger.shared.log("[BLE] Received \(data.count) bytes", debug: SettingsService.shared.debugBluetooth)
            onDataReceived?(data)
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothConnectionService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName = centralStateName(central.state)
        AppLogger.shared.log("[BLE] Central manager state: \(stateName)", debug: SettingsService.shared.debugBluetooth)
        if central.state != .poweredOn {
            setConnected(false)
            takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
            takeWriteContinuation()?.resume(throwing: ConnectionError.cancelled)
            takeReadContinuation()?.resume(throwing: ConnectionError.cancelled)
            cancelOperationWaiters()
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        let uuid = peripheral.identifier

        // Update known peripherals map (used for direct UUID-connect)
        knownPeripherals[uuid] = peripheral

        // Notify observers (e.g. AppCoordinator's scan UI)
        onPeripheralDiscovered?(peripheral, RSSI)

        // Check if this is our connection target:
        // 1. Match by UUID (preferred – stable across sessions)
        // 2. Fallback: match by name substring (legacy)
        let targetUUID = UUID(uuidString: targetDeviceAddress)
        let isUUIDMatch = targetUUID != nil && targetUUID == uuid
        let isNameMatch = !targetDeviceName.isEmpty && name.lowercased().contains(targetDeviceName.lowercased())

        if hasConnectContinuation && (isUUIDMatch || isNameMatch) {
            AppLogger.shared.log("[BLE] Found target device: \(name) (RSSI: \(RSSI))", debug: SettingsService.shared.debugBluetooth)
            centralManager.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }

        // Collect for scan list (avoid duplicates)
        if !discoveredPeripherals.contains(where: { $0.peripheral.identifier == uuid }) {
            discoveredPeripherals.append((peripheral, RSSI))
            AppLogger.shared.log("[BLE] Discovered: \(name) (RSSI: \(RSSI))", debug: SettingsService.shared.debugBluetooth)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let name = peripheral.name ?? "Unknown"
        AppLogger.shared.log("[BLE] Connected to: \(name)", debug: SettingsService.shared.debugBluetooth)
        peripheral.discoverServices([BluetoothConnectionService.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "Unknown"
        AppLogger.shared.log("[BLE] Failed to connect to \(name): \(error?.localizedDescription ?? "unknown error")", debug: true)
        takeConnectContinuation()?.resume(throwing: error ?? ConnectionError.cancelled)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let name = peripheral.name ?? "Unknown"
        if let error {
            AppLogger.shared.log("[BLE] Disconnected from \(name) with error: \(error.localizedDescription)", debug: true)
        } else {
            AppLogger.shared.log("[BLE] Disconnected from \(name)", debug: SettingsService.shared.debugBluetooth)
        }
        setConnected(false)
        pollingTask?.cancel()
        pollingTask = nil
        resetDrainState()
        takeWriteContinuation()?.resume(throwing: ConnectionError.cancelled)
        takeReadContinuation()?.resume(throwing: ConnectionError.cancelled)
        cancelOperationWaiters()
        onConnectionStateChanged?(false)
    }

    private func centralStateName(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOn: return "poweredOn"
        case .poweredOff: return "poweredOff"
        case .resetting: return "resetting"
        case .unauthorized: return "unauthorized"
        case .unsupported: return "unsupported"
        case .unknown: return "unknown"
        @unknown default: return "unknown(\(state.rawValue))"
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothConnectionService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            AppLogger.shared.log("[BLE] Service discovery failed: \(error.localizedDescription)", debug: true)
            takeConnectContinuation()?.resume(throwing: error)
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == BluetoothConnectionService.serviceUUID })
        else {
            AppLogger.shared.log("[BLE] Meshtastic service not found", debug: true)
            takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
            return
        }
        AppLogger.shared.log("[BLE] Discovered service, discovering characteristics...", debug: SettingsService.shared.debugBluetooth)
        peripheral.discoverCharacteristics([
            BluetoothConnectionService.toRadioUUID,
            BluetoothConnectionService.fromRadioUUID,
            BluetoothConnectionService.fromNumUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            AppLogger.shared.log("[BLE] Characteristic discovery failed: \(error.localizedDescription)", debug: true)
            takeConnectContinuation()?.resume(throwing: error)
            return
        }

        var foundChars: [String] = []
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case BluetoothConnectionService.toRadioUUID:
                toRadioChar = char
                foundChars.append("toRadio")
            case BluetoothConnectionService.fromRadioUUID:
                fromRadioChar = char
                foundChars.append("fromRadio")
            case BluetoothConnectionService.fromNumUUID:
                fromNumChar = char
                foundChars.append("fromNum")
            default: break
            }
        }
        AppLogger.shared.log("[BLE] Found characteristics: \(foundChars.joined(separator: ", "))", debug: SettingsService.shared.debugBluetooth)

        // Subscribe to FromNum notifications
        if let fn = fromNumChar {
            peripheral.setNotifyValue(true, for: fn)
            AppLogger.shared.log("[BLE] Subscribed to fromNum notifications", debug: SettingsService.shared.debugBluetooth)
        }

        guard toRadioChar != nil, fromRadioChar != nil else {
            AppLogger.shared.log("[BLE] Missing required characteristics (toRadio/fromRadio)", debug: true)
            takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
            return
        }

        setConnected(true)
        onConnectionStateChanged?(true)
        if fromNumChar != nil {
            triggerImmediateDrain()
            AppLogger.shared.log("[BLE] Connection ready, using fromNum-driven drain", debug: SettingsService.shared.debugBluetooth)
        } else {
            startPolling()
            AppLogger.shared.log("[BLE] Connection ready, using polling fallback", debug: SettingsService.shared.debugBluetooth)
        }
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        takeConnectContinuation()?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppLogger.shared.log("[BLE] Characteristic update error: \(error.localizedDescription)", debug: true)
            if characteristic.uuid == BluetoothConnectionService.fromRadioUUID {
                takeReadContinuation()?.resume(throwing: error)
            }
            return
        }

        if characteristic.uuid == BluetoothConnectionService.fromNumUUID {
            // fromNum notification: new data is available — trigger immediate drain
            triggerImmediateDrain()
            return
        }

        guard characteristic.uuid == BluetoothConnectionService.fromRadioUUID else { return }
        let data = characteristic.value ?? Data()

        if let cont = takeReadContinuation() {
            cont.resume(returning: data)
        } else if !data.isEmpty {
            // Defensive fallback for unsolicited FromRadio notifications.
            AppLogger.shared.log("[BLE] Received unsolicited \(data.count)-byte packet", debug: SettingsService.shared.debugBluetooth)
            onDataReceived?(data)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BluetoothConnectionService.toRadioUUID else { return }
        if let cont = takeWriteContinuation() {
            if let error {
                AppLogger.shared.log("[BLE] Write error: \(error.localizedDescription)", debug: true)
                cont.resume(throwing: error)
            } else {
                AppLogger.shared.log("[BLE] Write completed successfully", debug: SettingsService.shared.debugBluetooth)
                cont.resume()
                triggerImmediateDrain()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppLogger.shared.log("[BLE] Notification state update error: \(error.localizedDescription)", debug: true)
        } else {
            let state = characteristic.isNotifying ? "enabled" : "disabled"
            AppLogger.shared.log("[BLE] Notifications \(state) for \(characteristic.uuid.uuidString)", debug: SettingsService.shared.debugBluetooth)
        }
    }
}
