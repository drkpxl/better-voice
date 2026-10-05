import Foundation

/// Decides what one physical press of the dictation hotkey means: a tap toggles (today's
/// behaviour), a hold is push-to-talk (start on press, stop on release).
///
/// Pure and clock-free — the caller passes timestamps and owns the one timer this asks for — so
/// every edge case is unit-testable without a keyboard.
///
/// Two kinds of binding behave differently on press:
/// - **Combo** (⌥. — the default): the key-down is already unambiguous, so recording starts at
///   once and the hold is measured from the key-down to the modifier release.
/// - **Modifier-only** (e.g. Right Option): the same modifier is also part of everyday shortcuts
///   (⌥←, Right ⌘C), so a press alone proves nothing. Recording starts only once the press is shown
///   to be ours: a clean release (a tap → toggle on) or a clean hold past `holdThreshold` (→
///   push-to-talk). Any other key during the press makes it someone else's shortcut and it is
///   ignored — exactly the old `dictationModifierConsumed` guarantee, now also covering holds.
public struct DictationGesture: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case none
        case start
        case stop
        /// Discard a recording this press started: the "hold" was a slow shortcut after all.
        case cancel
        /// Call `holdTimerFired()` after `holdThreshold` unless the press has ended by then.
        case scheduleHoldTimer
    }

    /// A press shorter than this is a tap.
    public static let holdThreshold: TimeInterval = 0.3
    /// Another key this soon after a modifier-only hold started means it was a slow shortcut
    /// (Right ⌘ held, then C), not dictation.
    public static let shortcutGrace: TimeInterval = 0.5

    private enum State: Sendable, Equatable {
        case idle
        /// Modifier-only press, not yet proven to be a dictation gesture.
        case pending(since: TimeInterval)
        /// This press started the recording (combo key-down, or a modifier-only hold).
        case started(at: TimeInterval, holding: Bool)
        /// Recording was already running when this press began: release stops it.
        case stopOnRelease
        /// This press is not ours (another key joined it, or the module was busy).
        case ignored
    }

    private var state: State = .idle

    public init() {}

    /// Hotkey pressed. `isRecording`: a dictation is already running. `isBusy`: the module can't
    /// take a press right now (transcribing). `modifierOnly`: the binding has no key of its own.
    public mutating func down(at time: TimeInterval, isRecording: Bool, isBusy: Bool, modifierOnly: Bool) -> Action {
        if isBusy {
            state = .ignored
            return .none
        }
        if isRecording {
            state = .stopOnRelease
            return .none
        }
        if modifierOnly {
            state = .pending(since: time)
            return .scheduleHoldTimer
        }
        state = .started(at: time, holding: false)
        return .start
    }

    /// The hold timer requested by `.scheduleHoldTimer` elapsed with the modifier still down.
    public mutating func holdTimerFired(at time: TimeInterval) -> Action {
        guard case .pending = state else { return .none }
        state = .started(at: time, holding: true)
        return .start
    }

    /// Another key was pressed while a modifier-only binding was held.
    public mutating func otherKeyPressed(at time: TimeInterval) -> Action {
        switch state {
        case .pending, .stopOnRelease:
            state = .ignored
            return .none
        case .started(let start, holding: true):
            if time - start < Self.shortcutGrace {
                state = .ignored
                return .cancel
            }
            // A hold that's been recording a while is deliberate; a stray key doesn't end it.
            return .none
        case .idle, .ignored, .started:
            return .none
        }
    }

    /// Hotkey released.
    public mutating func up(at time: TimeInterval) -> Action {
        defer { state = .idle }
        switch state {
        case .idle, .ignored:
            return .none
        case .pending:
            // A clean tap of a modifier-only key: toggle on.
            return .start
        case .started(let start, let holding):
            return holding || time - start >= Self.holdThreshold ? .stop : .none
        case .stopOnRelease:
            return .stop
        }
    }

    /// Forget any in-progress press (binding changed, recording cancelled elsewhere).
    public mutating func reset() {
        state = .idle
    }
}
