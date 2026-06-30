import Foundation

/// Simple logger that writes to ~/.we/debug.log + the console
/// Automatically truncates and keeps the most recent half when over maxSize
enum Logger {
    private static let logURL = WEDataDir.logURL
    private static let queue = DispatchQueue(label: "we.logger", qos: .utility)
    private static let maxSize: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] WE:\(tag) \(message)"

        // Console
        print(line)

        // File
        queue.async {
            trimIfNeeded()
            let data = (line + "\n").data(using: .utf8) ?? Data()
            if FileManager.default.fileExists(atPath: logURL.path) {
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logURL)
            }
        }
    }

    /// Keeps the latter half of the log when it exceeds maxSize
    private static func trimIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxSize else { return }

        guard let data = try? Data(contentsOf: logURL) else { return }

        // Keep the latter half, cutting at a newline boundary
        let keepFrom = data.count / 2
        if let newlineIndex = data[keepFrom...].firstIndex(of: UInt8(ascii: "\n")) {
            let trimmed = data[(newlineIndex + 1)...]
            try? trimmed.write(to: logURL)
        }
    }
}
