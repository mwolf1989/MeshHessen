import Foundation
import CoreBluetooth

/// BLE connection to a Meshtastic node via CoreBluetooth
/// Implements the same polling loop as the Windows BLE service
final class BluetoothConnectionService: NSObject, ConnectionService {
    let type: ConnectionType = .bluetooth
    var onDataReceived: ((Data) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private(set) var isConnected: Bool = false

    // Meshtastic BLE service / characteristic UUIDs
    static let serviceUUID   = CBUUID(string: "6ba1b218-15a8-461f-9fa8-5dcae273eafd")
    static let toRadioUUID   = CBUUID(string: "f75c76d2-129e-4dad-a1dd-7866124401e7")
    static let fromRadioUUID = CBUUID(string: "2c55e69e-4993-11ed-b878-0242ac120002")
    static let fromNumUUID   = CBUUID(string: "ed9da18c-a800-4f66-a670-aa7547e34453")

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
    private var pendingWriteData: Data?
    private var writeContinuation: CheckedContinuation<Void, Error>?

    // Discovered peripherals during scan (keyed by UUID for fast lookup)
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    // Legacy array kept for external observers
    var discoveredPeripherals: [(peripheral: CBPeripheral, rssi: NSNumber)] = []
    var onPeripheralDiscovered: ((CBPeripheral, NSNumber) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .global(qos: .userInitiated))
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

    func connect(parameters: ConnectionParameters) async throws {
        guard case .bluetooth(let address, let name) = parameters else {
            AppLogger.shared.log("[BLE] Invalid connection parameters", debug: true)
            throw ConnectionError.invalidParameters
        }
        targetDeviceAddress = address
        targetDeviceName = name
        AppLogger.shared.log("[BLE] Connecting to device: \(name) (address: \(address))", debug: SettingsService.shared.debugBluetooth)

        // If we already know this peripheral (e.g. from a prior scan), connect directly
        if let uuid = UUID(uuidString: address), let known = knownPeripherals[uuid] {
            AppLogger.shared.log("[BLE] Peripheral already known – connecting directly to \(known.name ?? uuid.uuidString)", debug: SettingsService.shared.debugBluetooth)
            centralManager.stopScan()
            self.peripheral = known
            known.delegate = self
            return try await withCheckedThrowingContinuation { cont in
                self.storeConnectContinuation(cont)
                centralManager.connect(known, options: nil)
                self.startConnectTimeout()
            }
        }

        // Unknown UUID – scan for up to 20 s
        AppLogger.shared.log("[BLE] Peripheral unknown – starting scan (20 s timeout)", debug: SettingsService.shared.debugBluetooth)
        return try await withCheckedThrowingContinuation { cont in
            self.storeConnectContinuation(cont)
            centralManager.scanForPeripherals(
                withServices: [BluetoothConnectionService.serviceUUID],
                options: nil
            )
            self.startConnectTimeout()
            AppLogger.shared.log("[BLE] Scanning for peripherals...", debug: SettingsService.shared.debugBluetooth)
        }
    }

    func disconnect() {
        AppLogger.shared.log("[BLE] Disconnecting...", debug: SettingsService.shared.debugBluetooth)
        // Cancel any pending connect continuation to prevent CheckedContinuation leak/crash
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
        pollingTask?.cancel()
        pollingTask = nil
        centralManager.stopScan()
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        peripheral = nil
        toRadioChar = nil
        fromRadioChar = nil
        fromNumChar = nil
        isConnected = false
        onConnectionStateChanged?(false)
        AppLogger.shared.log("[BLE] Disconnected", debug: SettingsService.shared.debugBluetooth)
    }

    func write(_ data: Data) async throws {
        guard let p = peripheral, let char = toRadioChar, isConnected else {
            AppLogger.shared.log("[BLE] Write failed: not connected", debug: SettingsService.shared.debugBluetooth)
            throw ConnectionError.notConnected
        }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse

        AppLogger.shared.log("[BLE] Writing \(data.count) bytes (type: \(writeType == .withoutResponse ? "withoutResponse" : "withResponse"))", debug: SettingsService.shared.debugBluetooth)

        if writeType == .withoutResponse {
            p.writeValue(data, for: char, type: .withoutResponse)
            // Trigger a read after write (same as Windows client)
            Task { await self.drainFromRadio() }
        } else {
            return try await withCheckedThrowingContinuation { cont in
                self.storeWriteContinuation(cont)
                self.pendingWriteData = data
                p.writeValue(data, for: char, type: .withResponse)
            }
        }
    }

    func startScanning() {
        discoveredPeripherals.removeAll()
        knownPeripherals.removeAll()
        AppLogger.shared.log("[BLE] Started scanning for peripherals", debug: SettingsService.shared.debugBluetooth)
        centralManager.scanForPeripherals(
            withServices: [BluetoothConnectionService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
        AppLogger.shared.log("[BLE] Stopped scanning. Found \(discoveredPeripherals.count) peripherals", debug: SettingsService.shared.debugBluetooth)
    }

    // MARK: - Private

    private func startConnectTimeout() {        connectTimeoutTask?.cancel()
        connectTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard let self, !Task.isCancelled else { return }
            self.centralManager.stopScan()
            self.connectTimeoutTask = nil
            if let cont = self.takeConnectContinuation() {
                AppLogger.shared.log("[BLE] Connect timed out", debug: true)
                cont.resume(throwing: ConnectionError.timeout)
            }
        }
    }

    private func startPolling() {
        AppLogger.shared.log("[BLE] Starting polling loop (35ms interval)", debug: SettingsService.shared.debugBluetooth)
        pollingTask = Task { [weak self] in
            var iteration = 0
            while !Task.isCancelled {
                guard let self, self.isConnected else {
                    AppLogger.shared.log("[BLE] Polling stopped: not connected", debug: SettingsService.shared.debugBluetooth)
                    break
                }
                await self.drainFromRadio()
                try? await Task.sleep(for: .milliseconds(35))
                iteration += 1
                if iteration % 150 == 0 { // Log every ~5 seconds
                    AppLogger.shared.log("[BLE] Polling active (iteration \(iteration))", debug: SettingsService.shared.debugBluetooth)
                }
            }
            AppLogger.shared.log("[BLE] Polling task ended (cancelled: \(Task.isCancelled))", debug: SettingsService.shared.debugBluetooth)
        }
    }

    /// Triggers an immediate drain outside the polling loop (e.g. on fromNum notification).
    private func triggerImmediateDrain() {
        Task { await drainFromRadio() }
    }

    private func drainFromRadio() async {
        guard let p = peripheral, let char = fromRadioChar else { return }
        // Read multiple packets in a burst until no data is returned.
        // Each readValue triggers didUpdateValueFor asynchronously;
        // we read up to 32 times per drain to pull all queued packets.
        for _ in 0..<32 {
            guard isConnected else { break }
            p.readValue(for: char)
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothConnectionService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let stateName = centralStateName(central.state)
        AppLogger.shared.log("[BLE] Central manager state: \(stateName)", debug: SettingsService.shared.debugBluetooth)
        if central.state != .poweredOn {
            takeConnectContinuation()?.resume(throwing: ConnectionError.cancelled)
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
        isConnected = false
        pollingTask?.cancel()
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

        isConnected = true
        onConnectionStateChanged?(true)
        startPolling()
        AppLogger.shared.log("[BLE] Connection ready, started polling", debug: SettingsService.shared.debugBluetooth)
        connectTimeoutTask?.cancel()
        connectTimeoutTask = nil
        takeConnectContinuation()?.resume()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            AppLogger.shared.log("[BLE] Characteristic update error: \(error.localizedDescription)", debug: true)
            return
        }

        if characteristic.uuid == BluetoothConnectionService.fromNumUUID {
            // fromNum notification: new data is available — trigger immediate drain
            triggerImmediateDrain()
            return
        }

        guard characteristic.uuid == BluetoothConnectionService.fromRadioUUID,
              let data = characteristic.value, !data.isEmpty
        else { return }
        AppLogger.shared.log("[BLE] Received \(data.count) bytes", debug: SettingsService.shared.debugBluetooth)
        // BLE delivers raw protobuf with no framing
        onDataReceived?(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let cont = takeWriteContinuation() {
            if let error {
                AppLogger.shared.log("[BLE] Write error: \(error.localizedDescription)", debug: true)
                cont.resume(throwing: error)
            } else {
                AppLogger.shared.log("[BLE] Write completed successfully", debug: SettingsService.shared.debugBluetooth)
                cont.resume()
                // Trigger drain after write
                Task { await self.drainFromRadio() }
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
