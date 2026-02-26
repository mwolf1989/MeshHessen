import Foundation
import ORSSerial

/// Serial/USB connection to a Meshtastic node via ORSSerialPort
final class SerialConnectionService: NSObject, ConnectionService {
    let type: ConnectionType = .serial
    var onDataReceived: ((Data) -> Void)?
    var onConnectionStateChanged: ((Bool) -> Void)?

    private(set) var isConnected: Bool = false

    private var port: ORSSerialPort?
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var watchdogTimer: Timer?
    private var lastReceiveTime = Date()

    // MARK: - Public

    /// Returns available serial port names
    static var availablePorts: [String] {
        ORSSerialPortManager.shared().availablePorts.map { $0.path }
    }

    func connect(parameters: ConnectionParameters) async throws {
        guard case .serial(let portName, let baudRate) = parameters else {
            throw ConnectionError.invalidParameters
        }

        guard let serialPort = ORSSerialPort(path: portName) else {
            throw ConnectionError.invalidParameters
        }

        serialPort.baudRate = NSNumber(value: baudRate)
        serialPort.numberOfDataBits = 8
        serialPort.parity = .none
        serialPort.numberOfStopBits = 1
        serialPort.usesRTSCTSFlowControl = false
        serialPort.usesDTRDSRFlowControl = false
        serialPort.delegate = self

        self.port = serialPort

        return try await withCheckedThrowingContinuation { cont in
            self.connectContinuation = cont
            serialPort.open()
        }
    }

    func disconnect() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
        port?.close()
        port = nil
        isConnected = false
        onConnectionStateChanged?(false)
    }

    func write(_ data: Data) async throws {
        guard let port, isConnected else { throw ConnectionError.notConnected }
        port.send(data)
        // Small delay matching Windows client behavior
        try? await Task.sleep(for: .milliseconds(100))
    }

    // MARK: - Private

    /// Maps low-level serial errors to ``ConnectionError``.
    ///
    /// On macOS, `/dev/cu.*` devices are protected by TCC (Transparency, Consent,
    /// and Control). The ORSSerial adapter accesses serial ports through IOKit which
    /// surfaces POSIX `EPERM` (1) or `EACCES` (13) when TCC blocks the call.
    ///
    /// There is no dedicated Privacy key (like `NSCameraUsageDescription`) for serial
    /// ports — macOS Gatekeeper / TCC manages access by path. Re-plugging the USB
    /// adapter triggers a fresh TCC consent dialog.
    ///
    /// The entitlements file must include `com.apple.security.device.usb` (for USB
    /// serial adapters) and/or `com.apple.security.device.serial`.
    private static func mapSerialError(_ error: Error) -> Error {
        let nsErr = error as NSError
        // POSIX EPERM (1) or EACCES (13) from IOKit = sandbox or TCC permission denial
        if nsErr.domain == NSPOSIXErrorDomain && (nsErr.code == 1 || nsErr.code == 13) {
            return ConnectionError.notPermitted
        }
        return error
    }

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, self.isConnected else { return }
            if Date().timeIntervalSince(self.lastReceiveTime) > 30 {
                AppLogger.shared.log("[Serial] Watchdog timeout — disconnecting")
                self.disconnect()
            }
        }
    }
}

// MARK: - ORSSerialPortDelegate
extension SerialConnectionService: ORSSerialPortDelegate {
    func serialPortWasOpened(_ serialPort: ORSSerialPort) {
        isConnected = true
        lastReceiveTime = Date()
        onConnectionStateChanged?(true)
        startWatchdog()
        connectContinuation?.resume()
        connectContinuation = nil
    }

    func serialPort(_ serialPort: ORSSerialPort, didEncounterError error: Error) {
        let mapped = Self.mapSerialError(error)
        if let cont = connectContinuation {
            cont.resume(throwing: mapped)
            connectContinuation = nil
        }
        disconnect()
    }

    func serialPortWasRemovedFromSystem(_ serialPort: ORSSerialPort) {
        connectContinuation?.resume(throwing: ConnectionError.cancelled)
        connectContinuation = nil
        disconnect()
    }

    func serialPort(_ serialPort: ORSSerialPort, didReceive data: Data) {
        lastReceiveTime = Date()
        onDataReceived?(data)
    }
}
