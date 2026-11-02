import Foundation

/// "Bring this browser call window to the front", written against
/// `WindowSystem` so the window-ordering logic is testable.
public enum BrowserJump {
    /// Scripting path: the tab was found via the browser's AppleScript
    /// dictionary at (window, tab).
    public static func toTab(_ browser: Browser, window: Int, tab: Int,
                             system: any WindowSystem) -> Bool {
        let ok = system.runScript(MeetMatcher.jumpScript(for: browser, window: window, tab: tab)) != nil
        // Belt and suspenders for cross-Space / full-screen switching.
        if let pid = system.pids(bundleID: browser.bundleID).first {
            _ = system.activate(pid: pid, allWindows: true)
        }
        return ok
    }

    /// AX path: raise the exact window found at detect time (works across
    /// all profiles/incognito/PWAs). Activate WITHOUT allWindows so other
    /// windows don't pile on top of the raised one; if no title was found
    /// (mic-only fallback), activate everything — one window-switch away.
    public static func toWindow(_ browser: Browser, title: String?,
                                system: any WindowSystem) -> Bool {
        let pids = system.pids(bundleID: browser.bundleID)
        guard let title else {
            guard let pid = pids.first else { return false }
            return system.activate(pid: pid, allWindows: true)
        }
        let raised = pids.contains { system.raise(pid: $0, title: title) }
        let activated = pids.first.map { system.activate(pid: $0, allWindows: false) } ?? false
        return raised || activated
    }
}
