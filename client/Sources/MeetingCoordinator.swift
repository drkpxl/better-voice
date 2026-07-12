import AppKit
import Foundation
import BetterVoiceCore

/// Drives the menu-bar "Start Meeting Recording" flow. This is a FRONT DOOR only: it captures the
/// meeting's audio as TWO native-rate WAVs — the Mac's system output via `SystemAudioCapturer`
/// (required) and the user's own mic via `MicCapturer` (best-effort) — then hands both files off
/// into the EXISTING `ImportSession` → `ImportPipeline` → Apple Notes chain (see
/// `ImportSession.beginLiveMeeting(micFileURL:systemFileURL:)` and
/// `ImportLauncher.requestLiveMeeting(micFileURL:systemFileURL:)`) — it owns none of that
/// downstream work, only the capture lifecycle and the guardrails a LIVE recording needs on top
/// of an ordinary file import:
/// - gating Notes-readiness BEFORE any audio is captured (a recording nobody can save is
///   pointless, and worse, would silently prompt for System Audio Recording consent for nothing);
/// - never silently losing an in-progress recording if the app quits mid-meeting;
/// - never handing an empty/silent recording to the import pipeline (see `stopMeeting()`).
///
/// **Two-file design, not a mixed one-file recording**: `SystemAudioCapturer` and `MicCapturer`
/// each write their OWN WAV at their own native rate/clock — there is no mixing/resampling stage.
/// `ImportSession` transcribes (and, for the system file, diarizes) each file independently and
/// merges the results by timestamp. This eliminates cross-clock sample drift between the two
/// independently-clocked devices BY CONSTRUCTION (no cross-clock sample alignment ever happens),
/// matches how v1 worked, and gives ground-truth speaker attribution for free: the mic channel IS
/// the local user; the system channel is everyone else. See `MicCapturer`'s doc comment for the
/// v1 provenance and why a since-removed `MeetingAudioMixer` briefly mixed the two into one file.
///
/// Owned by `AppDelegate` (like `voiceModule`/`menuModel`), independent of any window, so
/// `MenuBarLabel`/`MenuBarMenu` can observe it whether or not the main window is open.
@MainActor
@Observable
final class MeetingCoordinator {

    /// The capture lifecycle as a single state machine. Modeling `starting` explicitly (rather
    /// than a pair of `isRecording`/`isStopping` bools) is what makes Stop safe DURING an
    /// in-flight `start()`: `stopMeeting()` holds the start `Task` and awaits it before tearing
    /// the tap down, so it can never null `capturer` out from under a `start()` that's still
    /// creating the Core Audio tap/aggregate/IOProc (which would leak an unstoppable tap and race
    /// the WAV's `finalize()` against a later `write()`).
    ///
    /// Transitions: `idle → starting → recording → stopping → idle`, plus `starting → idle`
    /// (start failed with no concurrent stop) and `starting → stopping` (Stop pressed mid-start).
    private enum State {
        case idle
        case starting(Task<Void, Never>)
        case recording
        case stopping
    }
    private var state: State = .idle

    // MARK: - Observable accessors (menu bar + quit guard)

    /// Show the recording badge / "Stop" menu row from the moment Start is pressed — capture is
    /// committed during `.starting` even though the tap isn't fully live yet.
    var isRecording: Bool {
        switch state {
        case .starting, .recording: return true
        case .idle, .stopping: return false
        }
    }
    /// Anything but fully idle — quitting could lose an in-progress or wrapping-up recording.
    /// `AppDelegate.applicationShouldTerminate` gates ⌘Q on this.
    var isActive: Bool {
        if case .idle = state { return false }
        return true
    }
    /// Start is only offered from a clean idle state.
    var canStart: Bool {
        if case .idle = state { return true }
        return false
    }
    /// Stop is only actionable once the tap is fully live — NOT during `.starting` (a Stop then
    /// would race `start()`; the menu row is disabled until this is true) or `.stopping`.
    var canStop: Bool {
        if case .recording = state { return true }
        return false
    }

    /// The Mac's system-audio tap — REQUIRED: a failure here aborts the whole meeting start (see
    /// `startMeeting()`'s error path).
    private var capturer: SystemAudioCapturer?
    /// The user's own mic — BEST-EFFORT: a denied/undetermined mic permission or missing audio
    /// device must not abort an otherwise-working meeting recording (see `startMeeting()`'s
    /// doc comment on why the mic is started after, and independently of, the system tap).
    private var micCapturer: MicCapturer?
    /// Where `capturer` is writing its system-audio WAV — the REQUIRED half of the two-file
    /// hand-off.
    private var systemFileURL: URL?
    /// Where `micCapturer` is writing its mic WAV — the BEST-EFFORT half; may end up empty/absent
    /// (never written, since `PCMWavWriter` opens lazily on first buffer) if the mic never
    /// captured anything.
    private var micFileURL: URL?

    // MARK: - Toggle

    func toggleMeeting() {
        if canStop {
            stopMeeting()
        } else if canStart {
            startMeeting()
        }
        // During `.starting`/`.stopping` the toggle is a no-op — the menu rows are disabled to
        // match, so this only guards a programmatic caller.
    }

    // MARK: - Start

    /// Gates BEFORE capturing any audio: the SAME Notes-configured + Automation-granted check
    /// `ImportSession.begin()` runs, just run early so Better Voice never records a meeting (and
    /// never triggers the system-audio TCC prompt) that has nowhere to be saved. On failure, opens
    /// the main window and drives a fresh `ImportSession.begin()` (via `ImportLauncher`), which
    /// re-hits the identical gate and renders the wizard's `.blocked` step — the user sees WHY
    /// (Notes not set up / Automation not granted) with its "Open Notes setup" / "Open Automation
    /// Settings" buttons, rather than a blank Step 1.
    func startMeeting() {
        guard case .idle = state else { return }

        let notesConfigured = RuntimeConfig.shared.notesConfigured
        let automationGranted = PermissionManager.isAutomationGranted()
        guard notesConfigured, automationGranted else {
            Logger.log("Meeting", "Start Meeting blocked — Apple Notes not ready (configured=\(notesConfigured), automation=\(automationGranted))")
            WindowRouter.shared.open(id: WindowID.main)
            ImportLauncher.shared.requestMeetingBlocked()
            return
        }

        let (systemFileURL, micFileURL) = Self.newRecordingURLs()
        let capturer = SystemAudioCapturer(audioFileURL: systemFileURL)
        let micCapturer = MicCapturer(audioFileURL: micFileURL)

        // `onAudioLevel` is documented as already hopped to the main queue by the time it's
        // invoked, but its `@Sendable` closure type carries no static proof of that to the
        // compiler — assert it via `assumeIsolated` rather than paying for a redundant extra
        // `DispatchQueue.main.async` hop (matches MarkdownEditorView.swift's /
        // EditorBenchHarness.swift's use of the same pattern for other guaranteed-main-thread,
        // non-actor-isolated callbacks). Both sources drive the same HUD level — whichever last
        // reported is shown, which in practice tracks "someone is talking right now" whether
        // that's the mic or the system side.
        let onLevel: @Sendable (Float) -> Void = { level in
            MainActor.assumeIsolated {
                RecordingIndicator.shared.update(level: level)
            }
        }
        capturer.onAudioLevel = onLevel
        micCapturer.onAudioLevel = onLevel

        self.capturer = capturer
        self.micCapturer = micCapturer
        self.systemFileURL = systemFileURL
        self.micFileURL = micFileURL

        RecordingIndicator.shared.show(owner: .meeting)
        Logger.log("Meeting", "Start Meeting Recording → system: \(systemFileURL.lastPathComponent), mic: \(micFileURL.lastPathComponent)")

        let task = Task { [weak self] in
            do {
                try await capturer.start()
                guard let self else { return }
                // Promote to `.recording` only if no concurrent Stop already moved us on — if a
                // Stop landed mid-start it's now `.stopping` and owns teardown/hand-off.
                if case .starting = self.state {
                    self.state = .recording
                }
            } catch {
                // NOTE: this only catches setup failures (tap/aggregate/IOProc creation). A
                // DENIED "System Audio Recording" permission does NOT throw — see
                // SystemAudioCapturer.start()'s doc comment; that case surfaces later as a
                // silent, empty/near-silent WAV, not here.
                Logger.log("Meeting", "SystemAudioCapturer failed to start: \(error)")
                guard let self else { return }
                // Only tear down here if no concurrent Stop is already doing so; otherwise
                // `stopMeeting()` owns the (idempotent) teardown of this same capturer.
                if case .starting = self.state {
                    capturer.close()
                    micCapturer.close()
                    self.capturer = nil
                    self.micCapturer = nil
                    self.systemFileURL = nil
                    self.micFileURL = nil
                    RecordingIndicator.shared.hide(owner: .meeting)
                    self.state = .idle
                    Notify.warn(
                        t("Couldn't start recording"),
                        t("Better Voice couldn't start capturing system audio. Try again, or check System Settings ▸ Privacy & Security ▸ System Audio Recording.")
                    )
                }
                return
            }

            // The system tap is the hard requirement (mirrors pre-existing behavior above); the
            // mic is ADDITIVE and best-effort — a denied/undetermined mic permission, or no audio
            // device at all, must not abort an otherwise-working meeting recording. Started
            // AFTER the system tap so a mic failure never interferes with the system-tap error
            // handling above, and so a Stop that lands during this window is still safely covered
            // by `stopMeeting()`'s `await startTask?.value` + idempotent `micCapturer.stop()`.
            do {
                try await micCapturer.start()
            } catch {
                Logger.log("Meeting", "MicCapturer failed to start (\(error)) — continuing with system audio only")
            }
        }
        state = .starting(task)
    }

    // MARK: - Stop

    /// Stops capture, finalizes both WAVs, then hands off to the main window's import wizard via
    /// `ImportLauncher` so the SAME transcribe → diarize → naming → summarizing → Notes chain
    /// `.audio` imports use processes it next — zero duplication here. Safe to call during
    /// `.starting`: it awaits the in-flight `start()` Task before `capturer.stop()` so stop can't
    /// race start.
    ///
    /// Bug 2 (now spanning BOTH files): before handing the recording off to the import wizard,
    /// checks whether EACH file is empty/silent (`isRecordingEffectivelyEmpty`) — e.g. a denied
    /// System Audio Recording permission (which doesn't throw at start, see
    /// `SystemAudioCapturer.start()`'s doc comment) combined with a denied/failed mic. The "no
    /// audio was captured" alert only fires when BOTH files are empty; if either has audio, the
    /// recording proceeds (with the empty side simply omitted from the hand-off — see
    /// `micFileURL` below). Neither WAV is ever deleted, even when both are empty (left on disk
    /// for debugging).
    func stopMeeting() {
        let startTask: Task<Void, Never>?
        switch state {
        case .recording:
            startTask = nil
        case .starting(let task):
            startTask = task
        case .idle, .stopping:
            return
        }
        guard let capturer, let micCapturer, let systemFileURL, let micFileURL else { return }
        state = .stopping
        self.capturer = nil
        self.micCapturer = nil
        self.systemFileURL = nil
        self.micFileURL = nil

        Task {
            // If a start() is still in flight, let it fully create (or fail to create) the tap
            // before we stop it — otherwise stop()/finalize() races start()/write().
            await startTask?.value
            await capturer.stop()
            await micCapturer.stop()
            RecordingIndicator.shared.hide(owner: .meeting)
            state = .idle

            let (systemEmpty, micEmpty) = await Task.detached(priority: .utility) {
                (
                    isRecordingEffectivelyEmpty(at: systemFileURL),
                    isRecordingEffectivelyEmpty(at: micFileURL)
                )
            }.value

            guard !(systemEmpty && micEmpty) else {
                Logger.log("Meeting", "Stop Meeting Recording — both system (\(systemFileURL.lastPathComponent)) and mic (\(micFileURL.lastPathComponent)) are empty/silent; not handing off to the import wizard (left on disk)")
                presentEmptyMeetingRecordingAlert()
                return
            }

            // Omit the mic file from the hand-off when it turned out empty (denied/failed mic, or
            // simply nobody spoke into it) — `ImportSession` falls back to system-only `.multi`
            // diarization in that case, matching pre-two-file behavior.
            let micHandoffURL = micEmpty ? nil : micFileURL
            Logger.log("Meeting", "Stop Meeting Recording — handing off system: \(systemFileURL.lastPathComponent), mic: \(micHandoffURL?.lastPathComponent ?? "none (empty/absent)") to the import wizard")

            // Open the window FIRST — ImportLauncher's contract requires this so the window's
            // ImportSession/onChange observer already exists before the request lands (see
            // ImportLauncher's doc comment).
            WindowRouter.shared.open(id: WindowID.main)
            ImportLauncher.shared.requestLiveMeeting(micFileURL: micHandoffURL, systemFileURL: systemFileURL)
        }
    }

    // MARK: - Cleanup (app quitting mid-recording)

    /// Tears down any live Core Audio tap / mic capture WITHOUT attempting the wizard hand-off —
    /// called from `AppDelegate.applicationWillTerminate`, after quitting mid-recording has
    /// already been confirmed (`isActive` gates `applicationShouldTerminate`), so nothing
    /// (tap/aggregate device/IOProc, mic capture session) leaks past process exit. Both partial
    /// WAVs are left on disk; there is no window left to hand them to at this point in shutdown.
    /// `close()` is idempotent on both, so this is safe even if a `.starting` Task is still
    /// mid-`start()`.
    func forceStopForQuit() {
        guard isActive else { return }
        capturer?.close()
        micCapturer?.close()
        capturer = nil
        micCapturer = nil
        systemFileURL = nil
        micFileURL = nil
        state = .idle
        RecordingIndicator.shared.hide(owner: .meeting)
    }

    // MARK: - Recording destination

    /// Fresh sibling WAV paths under the support directory for one live-capture recording's two
    /// files, sharing a common base name so they're easy to correlate on disk. Not cleaned up
    /// after a successful import (same as an ordinary `.audio` import never deletes its source
    /// file) — they're just no longer referenced by anything once the meeting is in Notes. (See
    /// the deferred cleanup note: `SupportDir/LiveMeetings/` can accumulate WAVs — an acknowledged
    /// trade-off for now.)
    private static func newRecordingURLs() -> (systemFileURL: URL, micFileURL: URL) {
        let dir = SupportDir.url.appendingPathComponent("LiveMeetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let base = "Meeting-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
        let systemFileURL = dir.appendingPathComponent("\(base).system.wav")
        let micFileURL = dir.appendingPathComponent("\(base).mic.wav")
        return (systemFileURL, micFileURL)
    }
}

// MARK: - Quit guard (mid-recording)

/// Confirm quitting while a meeting recording is in progress (or just finished and is still
/// wrapping up) — same shape as `confirmQuitDuringNotesSetupSave()`
/// (NotesDestinationPickerView.swift) / `confirmDiscardUnsavedImport()` (ImportWizardView.swift).
/// Returns true when the user chose to quit anyway; `applicationWillTerminate` then tears down
/// the capturer via `MeetingCoordinator.forceStopForQuit()`.
@MainActor
func confirmQuitDuringMeetingRecording() -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = t("A meeting is still recording")
    alert.informativeText = t("Quitting now stops the recording — it won't be transcribed or saved to Notes. Quit anyway?")
    alert.addButton(withTitle: t("Quit Anyway"))
    alert.addButton(withTitle: t("Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
}

// MARK: - Empty/silent recording (Bug 2)

/// Shown from `MeetingCoordinator.stopMeeting()` when BOTH the system and mic WAVs turned out
/// empty/silent — same shape as `confirmQuitDuringMeetingRecording()` above. Offers a direct deep
/// link to the System Audio Recording settings pane (`PermissionManager.openSettings(for:)`)
/// since a silently-denied "System Audio Recording" permission (see
/// `SystemAudioCapturer.start()`'s doc comment — a denial never throws, it just delivers silence)
/// is the most likely cause when the mic also didn't pick up enough to clear the silence
/// threshold.
@MainActor
func presentEmptyMeetingRecordingAlert() {
    NSApp.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = t("No audio was captured")
    alert.informativeText = t("Make sure audio was playing and that Better Voice has System Audio Recording permission (System Settings ▸ Privacy & Security).")
    alert.addButton(withTitle: t("Open Settings"))
    alert.addButton(withTitle: t("OK"))
    if alert.runModal() == .alertFirstButtonReturn {
        PermissionManager.openSettings(for: .systemAudio)
    }
}
