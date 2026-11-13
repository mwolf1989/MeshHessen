import Darwin
import Foundation

// Windows reference: MeshhessenClient/Services/Firmware/WifiOtaTransport.cs (WifiOtaDiscovery)

/// Listens for the ESP32 OTA loader's UDP beacon (`"Meshtastic_XXXX <version>"`, broadcast to
/// 255.255.255.255:3232 about once per second). The sender's address is the loader — DHCP may hand the
/// device a different IP in OTA mode than in normal operation.
enum OtaBeaconListener {
    static let port: UInt16 = 3232

    /// Same pattern as Windows (hex digits in either case; the loader's name suffix follows the
    /// firmware's device-name format).
    /// True when `payload` is an OTA loader beacon.
    static func isBeacon(_ payload: Data) -> Bool {
        guard let text = String(data: payload, encoding: .ascii) else { return false }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.wholeMatch(of: #/Meshtastic_[0-9A-Fa-f]{4}\s+\S{1,32}/#) != nil
    }

    /// IPv4 address (dotted) of the first beacon sender within `timeout`, or nil on timeout, bind failure
    /// or cancellation. Polls a non-blocking socket so cancellation is honoured within ~100 ms.
    static func discover(timeout: Duration, port: UInt16 = OtaBeaconListener.port) async -> String? {
        let socketFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketFD >= 0 else {
            AppLogger.shared.log("[OTA/WiFi] Beacon socket failed: errno \(errno)")
            return nil
        }
        defer { close(socketFD) }

        var yes: Int32 = 1
        let optionSize = socklen_t(MemoryLayout<Int32>.size)
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEADDR, &yes, optionSize)
        setsockopt(socketFD, SOL_SOCKET, SO_REUSEPORT, &yes, optionSize)
        _ = fcntl(socketFD, F_SETFL, fcntl(socketFD, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            AppLogger.shared.log("[OTA/WiFi] Beacon bind on UDP \(port) failed: errno \(errno)")
            return nil
        }

        AppLogger.shared.log("[OTA/WiFi] Listening for loader beacon on UDP \(port) (\(timeout))")
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var buffer = [UInt8](repeating: 0, count: 512)
        while ContinuousClock.now < deadline, !Task.isCancelled {
            var sender = sockaddr_in()
            var senderLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &sender) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(socketFD, bytes.baseAddress, bytes.count, 0, $0, &senderLength)
                    }
                }
            }
            if count > 0 {
                let payload = Data(buffer[0..<count])
                if sender.sin_family == sa_family_t(AF_INET), isBeacon(payload) {
                    let ip = ipv4String(sender.sin_addr)
                    AppLogger.shared.log("[OTA/WiFi] Loader beacon from \(ip)")
                    return ip
                }
                continue
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        AppLogger.shared.log("[OTA/WiFi] No loader beacon received")
        return nil
    }

    static func ipv4String(_ address: in_addr) -> String {
        var addr = address
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil else { return "" }
        return String(cString: text)
    }
}
