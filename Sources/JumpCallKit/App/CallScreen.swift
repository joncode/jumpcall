import AppKit

/// Answers "is the user looking at this call right now?" — the input for
/// the hotkey's jump⇄back toggle and the icon's jump-vs-menu decision.
@MainActor
enum CallScreen {
    static func isOn(_ handle: CallHandle) -> Bool {
        guard let bundleID = handle.activateBundleID,
              let front = NSWorkspace.shared.frontmostApplication,
              front.bundleIdentifier == bundleID else { return false }
        // Native call apps: being frontmost is enough.
        guard handle.browserID != nil else { return true }
        // Browser calls: the browser being frontmost could be any window
        // (other profile, email…) — check the FOCUSED window's title.
        guard let title = AXWindowProbe.focusedWindowTitle(pid: front.processIdentifier) else {
            // No Accessibility: the app-level check is the best we have.
            return true
        }
        if let axTitle = handle.axWindowTitle, title == axTitle { return true }
        return AXWindowProbe.titleLooksLikeCall(title)
    }
}
