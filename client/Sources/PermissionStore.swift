import AppKit
import Observation

/// A seam over the real TCC queries so `PermissionStore`'s state handling can be driven with a
/// fake (previews / any future host-test target) instead of hitting live TCC.
protocol PermissionProbing: Sendable {
    func isGranted(_ kind: PermissionKind) -> Bool
}

/// Production probe: delegates to `PermissionKind.isGranted` — the pure, NO-PROMPT queries in
/// `PermissionManager`. `.systemAudio` resolves to `false` here but is never surfaced as a live
/// status (see `PermissionKind.systemAudio` and `PermissionStore.isGranted`).
struct SystemPermissionProbe: PermissionProbing {
    func isGranted(_ kind: PermissionKind) -> Bool { kind.isGranted ?? false }
}

/// The single source of truth for live permission state, shared by the menu bar AND onboarding.
///
/// **Why this exists (root-cause of the stale menu bar):** the menu used to read
/// `PermissionKind.isGranted` as a plain, un-observed function call, so SwiftUI built the menu
/// once (at launch, when nothing was granted) and never re-invalidated it when a permission
/// changed out of process — hence the menu showing "Not authorized" while onboarding, polling on
/// its own timer, showed the same permissions as granted. Reading this `@Observable` store instead
/// means any `refresh()` that actually changes a value re-renders every observer, exactly the way
/// the already-correct meeting Start/Stop row stays live off `MeetingCoordinator`.
///
/// Only the *queryable* permissions the app actually surfaces live here. `.systemAudio` is
/// deliberately excluded: macOS exposes no API to query it (see `PermissionKind.systemAudio`), so
/// it never gets a live ✓/⚠ row.
@MainActor
@Observable
final class PermissionStore {
    static let shared = PermissionStore()

    private let probe: PermissionProbing

    private(set) var accessibility = false
    private(set) var microphone = false
    private(set) var automation = false

    init(probe: PermissionProbing = SystemPermissionProbe()) {
        self.probe = probe
        refresh()
    }

    /// Observed granted-state for a kind. `.systemAudio` always reports `false` and must not be
    /// rendered as a live status (callers handle it out of band — see `PermissionKind.systemAudio`).
    func isGranted(_ kind: PermissionKind) -> Bool {
        switch kind {
        case .accessibility:   return accessibility
        case .microphone:      return microphone
        case .automation:      return automation
        case .systemAudio:     return false
        }
    }

    /// Re-query every kind. Assignments are gated on an actual change so an idle refresh (the
    /// activation / menu-open / poll triggers all fire often) doesn't churn observers into
    /// needless re-renders. Returns whether anything changed, letting callers react to a fresh
    /// grant (onboarding auto-advance, healing the hotkey tap).
    @discardableResult
    func refresh() -> Bool {
        let newAccess = probe.isGranted(.accessibility)
        let newMic    = probe.isGranted(.microphone)
        let newAuto   = probe.isGranted(.automation)

        var changed = false
        if newAccess != accessibility { accessibility = newAccess; changed = true }
        if newMic    != microphone    { microphone    = newMic;    changed = true }
        if newAuto   != automation    { automation    = newAuto;   changed = true }
        return changed
    }
}
