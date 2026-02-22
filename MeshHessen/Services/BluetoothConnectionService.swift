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
    private var targetDeviceName: String = ""
    private var targetDeviceAddress: String = ""
    private var pollingTask: Task<Void, Never>?
    private var pendingWriteData: Data?
    private var writeContinuation: CheckedContinuation<Void, Error>?

    // Discovered peripherals during scan
    var discoveredPeripherals: [(peripheral: CBPeripheral, rssi: NSNumber)] = []
    var onPeripheralDiscovered: ((CBPeripheral, NSNumber) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: .global(qos: .userInitiated))
    }

    func connect(parameters: ConnectionParameters) async throws {
        guard case .bluetooth(let address, let name) = parameters else {
            throw ConnectionError.invalidParameters
        }
        targetDeviceAddress = address
        targetDeviceName = name

        return try await withCheckedThrowingContinuation { cont in
            self.connectContinuation = cont
            // Scan for the target device
            centralManager.scanForPeripherals(
                withServices: [BluetoothConnectionService.serviceUUID],
                options: nil
            )
        }
    }

    func disconnect() {
        pollingTask?.cancel()
        pollingTask = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        peripheral = nil
        toRadioChar = nil
        fromRadioChar = nil
        fromNumChar = nil
        isConnected = false
        onConnectionStateChanged?(false)
    }

    func write(_ data: Data) async throws {
        guard let p = peripheral, let char = toRadioChar, isConnected else {
            throw ConnectionError.notConnected
        }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.writeWithoutResponse)
            ? .withoutResponse : .withResponse

        if writeType == .withoutResponse {
            p.writeValue(data, for: char, type: .withoutResponse)
            // Trigger a read after write (same as Windows client)
            Task { await self.drainFromRadio() }
        } else {
            return try await withCheckedThrowingContinuation { cont in
                self.writeContinuation = cont
                self.pendingWriteData = data
                p.writeValue(data, for: char, type: .withResponse)
            }
        }
    }

    func startScanning() {
        discoveredPeripherals.removeAll()
        centralManager.scanForPeripherals(
            withServices: [BluetoothConnectionService.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func stopScanning() {
        centralManager.stopScan()
    }

    // MARK: - Private

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.isConnected else { break }
                await self.drainFromRadio()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func drainFromRadio() async {
        guard let p = peripheral, let char = fromRadioChar else { return }
        // Read repeatedly until empty (0 bytes)
        while isConnected {
            p.readValue(for: char)
            // Small delay to allow delegate to fire
            try? await Task.sleep(for: .milliseconds(20))
            // The delegate fires onDataReceived; we just keep looping
            // Stop condition handled by empty-data check in delegate
            break // CoreBluetooth is event-driven; one read per drain cycle
        }
    }
}

// MARK: - CBCentralManagerDelegate
extension BluetoothConnectionService: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn {
            connectContinuation?.resume(throwing: ConnectionError.cancelled)
            connectContinuation = nil
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? "Unknown"
        onPeripheralDiscovered?(peripheral, RSSI)

        // Check if this is our target
        if !targetDeviceName.isEmpty && name.contains(targetDeviceName) {
            centralManager.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            centralManager.connect(peripheral, options: nil)
        }

        // Also collect for scan list
        if !discoveredPeripherals.contains(where: { $0.peripheral.identifier == peripheral.identifier }) {
            discoveredPeripherals.append((peripheral, RSSI))
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BluetoothConnectionService.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectContinuation?.resume(throwing: error ?? ConnectionError.cancelled)
        connectContinuation = nil
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        isConnected = false
        pollingTask?.cancel()
        onConnectionStateChanged?(false)
    }
}

// MARK: - CBPeripheralDelegate
extension BluetoothConnectionService: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == BluetoothConnectionService.serviceUUID })
        else {
            connectContinuation?.resume(throwing: error ?? ConnectionError.cancelled)
            connectContinuation = nil
            return
        }
        peripheral.discoverCharacteristics([
            BluetoothConnectionService.toRadioUUID,
            BluetoothConnectionService.fromRadioUUID,
            BluetoothConnectionService.fromNumUUID
        ], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            connectContinuation?.resume(throwing: error!)
            connectContinuation = nil
            return
        }
        for char in service.characteristics ?? [] {
            switch char.uuid {
            case BluetoothConnectionService.toRadioUUID:   toRadioChar = char
            case BluetoothConnectionService.fromRadioUUID: fromRadioChar = char
            case BluetoothConnectionService.fromNumUUID:   fromNumChar = char
            default: break
            }
        }

        // Subscribe to FromNum notifications
        if let fn = fromNumChar { peripheral.setNotifyValue(true, for: fn) }

        guard toRadioChar != nil, fromRadioChar != nil else {
            connectContinuation?.resume(throwing: ConnectionError.cancelled)
            connectContinuation = nil
            return
        }

        isConnected = true
        onConnectionStateChanged?(true)
        startPolling()
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == BluetoothConnectionService.fromRadioUUID,
              let data = characteristic.value, !data.isEmpty
        else { return }
        // BLE delivers raw protobuf with no framing
        onDataReceived?(data)
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let cont = writeContinuation {
            if let error {
                cont.resume(throwing: error)
            } else {
                cont.resume()
                // Trigger drain after write
                Task { await self.drainFromRadio() }
            }
            writeContinuation = nil
        }
    }
}
