import Foundation

/// Simple logger that writes to ~/Library/Logs/BetterVoice2/debug.log + the console.
/// Automatically truncates and keeps the most recent half when over maxSize.
///
/// The log lives at a FIXED path, independent of the user's chosen workspace folder:
/// onboarding (and any early-launch failures) must be able to log before a workspace exists.
enum Logger {
    static let logDirectory: URL = {
        // Dev builds carry a `.dev` bundle id (see scripts/apply-channel.sh) so they can run beside
        // the release build; give them their own log dir so the two channels don't interleave.
        let isDev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") ?? false
        let folder = isDev ? "BetterVoice2-Dev" : "BetterVoice2"
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/\(folder)", isDirectory: true)
    }()

    private static let logURL: URL = logDirectory.appendingPathComponent("debug.log")
    private static let queue = DispatchQueue(label: "bettervoice.logger", qos: .utility)
    private static let maxSize: UInt64 = 5 * 1024 * 1024  // 5 MB
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ tag: String, _ message: String) {
        let timestamp = dateFormatter.string(from: Date())
        let line = "[\(timestamp)] BetterVoice:\(tag) \(message)"

        // Console
        print(line)

        // File
        queue.async {
            ensureLogDirectory()
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

    private static func ensureLogDirectory() {
        if !FileManager.default.fileExists(atPath: logDirectory.path) {
            try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
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
