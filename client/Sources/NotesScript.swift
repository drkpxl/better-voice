import BetterVoiceCore
import Foundation

/// Minimal, write-only bridge to Apple Notes via AppleScript (`/usr/bin/osascript`).
///
/// Every dynamic value (account/folder names, folder ids, note titles) is passed as an `argv`
/// element to an `on run argv` script — never string-interpolated into the script source — so
/// user/meeting content can never break out of a quoted AppleScript literal (no escaping bugs,
/// no injection). The one exception is the note HTML body, which goes through a 0600 temp file
/// (path passed as argv) instead: argv is visible to every local user via `ps -eww` while the
/// process runs, and full transcripts could also approach the ~1 MB ARG_MAX ceiling.
///
/// Every call wraps its `tell application "Notes"` work in `with timeout of 20 seconds` (Notes
/// can be slow to wake up from a cold launch) and retries once, after a short delay, if the
/// first attempt fails *transiently* (timeout or a process launch failure). Deterministic
/// failures — a stale folder id, unparseable output — propagate immediately.
///
/// This module is deliberately act-only: it creates folders/notes and can reveal a note in the
/// Notes UI, but it never reads note bodies back. That keeps the trust boundary simple — Better
/// Voice writes to Notes, it doesn't need to parse arbitrary user-edited Notes content.
enum NotesScript {

    enum NotesScriptError: LocalizedError {
        case osascriptFailed(status: Int32, stderr: String)
        case timeout
        case parseFailure(String)

        var errorDescription: String? {
            switch self {
            case .osascriptFailed(let status, let stderr):
                return "Apple Notes command failed (osascript exited \(status)): \(stderr)"
            case .timeout:
                return "Apple Notes did not respond in time."
            case .parseFailure(let detail):
                return "Couldn't parse Apple Notes' response: \(detail)"
            }
        }
    }

    private static let fieldDelimiter = NotesScriptOutput.fieldDelimiter

    private static let timeoutSeconds: TimeInterval = 20
    /// Hard backstop above the AppleScript-level `with timeout of 20 seconds`, covering the
    /// case where `osascript` itself (not just the Apple event) hangs.
    private static let processTimeoutSeconds: TimeInterval = 25
    /// After SIGTERM, how long the watchdog waits before escalating to SIGKILL.
    private static let killGraceSeconds: TimeInterval = 5

    // MARK: - Public API

    static func listAccounts() throws -> [String] {
        let script = """
        on run argv
            with timeout of \(Int(timeoutSeconds)) seconds
                tell application "Notes"
                    set out to ""
                    repeat with a in accounts
                        set out to out & (name of a) & linefeed
                    end repeat
                    return out
                end tell
            end timeout
        end run
        """
        let output = try runWithRetry(script: script, args: [])
        return NotesScriptOutput.lines(of: output)
    }

    static func listFolders(account: String) throws -> [(id: String, name: String)] {
        let script = """
        on run argv
            set accountName to item 1 of argv
            with timeout of \(Int(timeoutSeconds)) seconds
                tell application "Notes"
                    set theAccount to account accountName
                    set out to ""
                    repeat with f in folders of theAccount
                        set out to out & ((id of f) as text) & "\(fieldDelimiter)" & (name of f) & linefeed
                    end repeat
                    return out
                end tell
            end timeout
        end run
        """
        let output = try runWithRetry(script: script, args: [account])
        return try records(of: output)
    }

    static func createFolder(account: String, name: String) throws -> (id: String, name: String) {
        let script = """
        on run argv
            set accountName to item 1 of argv
            set folderName to item 2 of argv
            with timeout of \(Int(timeoutSeconds)) seconds
                tell application "Notes"
                    set theAccount to account accountName
                    set newFolder to make new folder at theAccount with properties {name:folderName}
                    return ((id of newFolder) as text) & "\(fieldDelimiter)" & (name of newFolder)
                end tell
            end timeout
        end run
        """
        let output = try runWithRetry(script: script, args: [account, name])
        guard let record = try records(of: output).first else {
            throw NotesScriptError.parseFailure("createFolder returned no record: \(output)")
        }
        return record
    }

    /// Creates a note in `folderId` (looked up by id under `account`) and returns its new id.
    ///
    /// `html` MUST start with an `<h1>` title line: Apple Notes derives the note's visible
    /// title from the first line of the HTML body, there is no separate "title" property to
    /// set. `name` is not sent to Notes (setting `name` explicitly is ignored/overridden once
    /// `body` is set) — it's kept in the signature for logging/API symmetry with the other
    /// calls and so callers have a stable display label even before the note round-trips.
    ///
    /// The HTML travels via a 0600 temp file (see the type doc comment), read back inside the
    /// script with `read POSIX file … as «class utf8»`; only the file path rides in argv.
    ///
    /// Folder targeting is by id (`folder id "x-coredata://…" of theAccount`), the stable
    /// handle Notes gives every folder. If the id no longer resolves (e.g. the user deleted or
    /// recreated the folder since it was chosen), this throws `.osascriptFailed` with a message
    /// identifying the stale id — callers should re-resolve the folder by name and retry.
    static func createNote(account: String, folderId: String, name: String, html: String) throws -> String {
        let script = """
        on run argv
            set accountName to item 1 of argv
            set folderId to item 2 of argv
            set htmlPath to item 4 of argv
            set noteHTML to read POSIX file htmlPath as «class utf8»
            with timeout of \(Int(timeoutSeconds)) seconds
                tell application "Notes"
                    set theAccount to account accountName
                    try
                        set theFolder to folder id folderId of theAccount
                    on error
                        error "BV_FOLDER_NOT_FOUND: " & folderId
                    end try
                    set newNote to make new note at theFolder with properties {body:noteHTML}
                    return (id of newNote) as text
                end tell
            end timeout
        end run
        """
        let htmlURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bettervoice-note-body-\(UUID().uuidString)")
            .appendingPathExtension("html")
        // createFile(atPath:contents:attributes:) applies 0600 at creation — no window where
        // the body is readable by other local users.
        guard FileManager.default.createFile(
            atPath: htmlURL.path,
            contents: Data(html.utf8),
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: htmlURL.path])
        }
        defer { try? FileManager.default.removeItem(at: htmlURL) }

        let output = try runWithRetry(script: script, args: [account, folderId, name, htmlURL.path])
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NotesScriptError.parseFailure("createNote returned an empty id")
        }
        return trimmed
    }

    /// Brings Notes.app to the foreground with the given note open.
    static func showNote(id: String) throws {
        let script = """
        on run argv
            set noteId to item 1 of argv
            with timeout of \(Int(timeoutSeconds)) seconds
                tell application "Notes"
                    show note id noteId
                    activate
                end tell
            end timeout
        end run
        """
        _ = try runWithRetry(script: script, args: [id])
    }

    // MARK: - Parsing helpers

    private static func records(of output: String) throws -> [(id: String, name: String)] {
        do {
            return try NotesScriptOutput.records(of: output)
        } catch let NotesScriptOutput.ParseError.wrongFieldCount(expected, got, line) {
            throw NotesScriptError.parseFailure("expected \(expected) fields, got \(got): \(line)")
        }
    }

    // MARK: - Process execution

    /// Runs `script` once; retries exactly once, after a short delay, on *transient* failures
    /// only. Deterministic failures (`.parseFailure`, `.osascriptFailed` — e.g. the stale
    /// folder id `BV_FOLDER_NOT_FOUND` error) would just fail identically again, so they
    /// propagate immediately instead of wasting up to another timeout window.
    private static func runWithRetry(script: String, args: [String]) throws -> String {
        do {
            return try run(script: script, args: args)
        } catch let error where isTransient(error) {
            Logger.log("NotesScript", "First attempt failed (\(error.localizedDescription)), retrying once")
            Thread.sleep(forTimeInterval: 0.5)
            return try run(script: script, args: args)
        }
    }

    /// `.timeout` (watchdog kill or AppleScript event timeout) and process-level launch
    /// failures (non-`NotesScriptError`, e.g. `Process.run()` throwing) are worth one retry;
    /// every `NotesScriptError` besides `.timeout` is deterministic.
    private static func isTransient(_ error: Error) -> Bool {
        switch error {
        case NotesScriptError.timeout: return true
        case is NotesScriptError: return false
        default: return true
        }
    }

    /// Thread-safe "did the watchdog fire" flag, shared between the watchdog work item and the
    /// exit-status interpretation in `run`.
    private final class WatchdogFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func mark() { lock.lock(); value = true; lock.unlock() }
        var didFire: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// Thread-safe box for the pipe-drain results (written on background queues, read after
    /// `readGroup.wait()` — the lock also publishes the writes to the waiting thread).
    private final class DataBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ new: Data) { lock.lock(); data = new; lock.unlock() }
        var value: Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    private static func run(script: String, args: [String]) throws -> String {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bettervoice-notes-\(UUID().uuidString)")
            .appendingPathExtension("applescript")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: scriptURL) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = [scriptURL.path] + args

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Read both pipes concurrently while the process runs — reading them sequentially
        // after waitUntilExit() can deadlock if a pipe's buffer fills before it's drained.
        let stdoutBox = DataBox()
        let stderrBox = DataBox()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutBox.set(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBox.set(stderrPipe.fileHandleForReading.readDataToEndOfFile())
            readGroup.leave()
        }

        // Hard backstop above the AppleScript-level timeout, in case osascript itself hangs:
        // SIGTERM first, then SIGKILL after a grace period if osascript ignored it, so
        // waitUntilExit() below is guaranteed to return.
        let watchdogFlag = WatchdogFlag()
        let watchdog = DispatchWorkItem {
            guard process.isRunning else { return }
            watchdogFlag.mark()
            Logger.log("NotesScript", "osascript exceeded \(processTimeoutSeconds)s, terminating")
            process.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + killGraceSeconds) {
                if process.isRunning {
                    Logger.log("NotesScript", "osascript ignored SIGTERM, sending SIGKILL")
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + processTimeoutSeconds, execute: watchdog)

        process.waitUntilExit()
        watchdog.cancel()
        readGroup.wait()

        let stderr = String(data: stderrBox.value, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationReason == .uncaughtSignal {
            // Only the watchdog's own kill is a timeout; any other signal (crash, external
            // kill) is reported as what it is, not mislabeled as Notes being slow.
            if watchdogFlag.didFire {
                throw NotesScriptError.timeout
            }
            throw NotesScriptError.osascriptFailed(status: process.terminationStatus, stderr: stderr)
        }
        guard process.terminationStatus == 0 else {
            // `with timeout of N seconds` expiring surfaces as AppleScript error -1712 with a
            // nonzero exit — that's the transient "Notes didn't answer" case, not a script bug.
            // Parenthesized to match osascript's trailing " (-1712)" only — a bare "-1712" can
            // legitimately appear inside a Core Data folder id in the error message.
            if stderr.contains("(-1712)") {
                throw NotesScriptError.timeout
            }
            throw NotesScriptError.osascriptFailed(status: process.terminationStatus, stderr: stderr)
        }

        return String(data: stdoutBox.value, encoding: .utf8) ?? ""
    }
}
