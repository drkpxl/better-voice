import ApplicationServices

/// Captures and restores the exact UI element (text field) that had keyboard focus when
/// dictation started. Reactivating just the owning app isn't enough: a long transcription
/// that finishes after the user clicked into a different field — even within the same app —
/// would otherwise paste into the wrong place. We snapshot the focused AXUIElement at start
/// and re-focus *it* right before the ⌘V paste.
///
/// Requires the Accessibility permission (already needed for text injection). All calls run
/// on the main actor alongside the rest of the dictation flow.
@MainActor
enum FocusTarget {
    /// The system-wide focused UI element at the moment of call (nil if none / not permitted).
    static func capture() -> AXUIElement? {
        attribute(of: AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute)
    }

    /// Raise the element's window and re-focus the element itself. Harmless no-op if the
    /// element is nil or has since become invalid (AX errors are ignored).
    static func restore(_ element: AXUIElement?) {
        guard let element else { return }
        if let window = attribute(of: element, kAXWindowAttribute) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Read an AXUIElement-typed attribute; nil if absent or the wrong type.
    private static func attribute(of element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}
