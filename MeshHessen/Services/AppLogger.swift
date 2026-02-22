import Foundation

/// Application-wide rotating log (file + in-memory for Debug view)
final class AppLogger {
    static let shared = AppLogger()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "logger", qos: .background)
    private let maxFileSize: Int = 5 * 1024 * 1024  // 5 MB

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("MeshHessen", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("meshhessen.log")
    }

    /// Log a message to file and optionally post to the debug view
    func log(_ message: String, debug: Bool = false) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"

        queue.async {
            self.rotateIfNeeded()
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: self.fileURL.path) {
                    if let fh = try? FileHandle(forWritingTo: self.fileURL) {
                        fh.seekToEndOfFile()
                        fh.write(data)
                        try? fh.close()
                    }
                } else {
                    try? data.write(to: self.fileURL)
                }
            }
        }

        // Post to AppState debug tab on main thread
        if debug {
            Task { @MainActor in
                // AppState is accessed through the shared protocol service coordinator
                NotificationCenter.default.post(
                    name: .appLogLine,
                    object: nil,
                    userInfo: ["line": "[\(ts)] \(message)"]
                )
            }
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? Int, size > maxFileSize
        else { return }
        let rotated = fileURL.deletingLastPathComponent()
            .appendingPathComponent("meshhessen.log.old")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: fileURL, to: rotated)
    }
}

extension Notification.Name {
    static let appLogLine = Notification.Name("MeshHessen.appLogLine")
}
