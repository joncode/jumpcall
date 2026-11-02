import Foundation

/// "Bring this browser call window to the front", written against
/// `WindowSystem` so the window-ordering logic is testable.
///
/// Switching to the right app/Space is not enough: with two same-size
/// browser windows on one Space, the call window can stay entirely behind
/// the other one. Chrome's `set index of window` doesn't reliably move the
/// real window, and activating the app brings back its previous key window.
/// So every jump ends by raising the exact call window via Accessibility,
/// making it the main window, activating, and verifying it has focus.
public enum BrowserJump {
    /// Scripting path: the tab was found via the browser's AppleScript
    /// dictionary at (window, tab). The script selects the tab and returns
    /// its title, which identifies the window to raise.
    public static func toTab(_ browser: Browser, window: Int, tab: Int,
                             system: any WindowSystem) -> Bool {
        let tabTitle = system.runScript(MeetMatcher.jumpScript(for: browser, window: window, tab: tab))
        let pids = system.pids(bundleID: browser.bundleID)
        if let tabTitle, let target = findWindow(titled: tabTitle, pids: pids, system: system) {
            return bringForward(target, system: system)
        }
        // No Accessibility permission (or no matching window): the best we
        // can do is activate the browser and hope its key window is the call.
        if let pid = pids.first {
            _ = system.activate(pid: pid, allWindows: true)
        }
        return tabTitle != nil
    }

    /// AX path: raise the exact window found at detect time (works across
    /// all profiles/incognito/PWAs). If no title was found (mic-only
    /// fallback), activate everything — one window-switch away.
    public static func toWindow(_ browser: Browser, title: String?,
                                system: any WindowSystem) -> Bool {
        let pids = system.pids(bundleID: browser.bundleID)
        guard let title else {
            guard let pid = pids.first else { return false }
            return system.activate(pid: pid, allWindows: true)
        }
        if let target = findWindow(titled: title, pids: pids, system: system) {
            return bringForward(target, system: system)
        }
        return pids.first.map { system.activate(pid: $0, allWindows: false) } ?? false
    }

    /// Exact title first; then a prefix match, because the AX window title
    /// can carry a suffix the tab title lacks (e.g. " - Work" for a profile).
    static func findWindow(titled title: String, pids: [pid_t],
                           system: any WindowSystem) -> WindowRef? {
        guard !title.isEmpty else { return nil }
        let windows = pids.flatMap { system.windows(pid: $0) }
        return windows.first { $0.title == title }
            ?? windows.first { $0.title.hasPrefix(title) }
    }

    /// Un-minimize, raise, make main, activate (switching to the window's
    /// Space), then verify it really has focus. One retry: activation can
    /// hand focus back to the app's previous key window.
    static func bringForward(_ window: WindowRef, system: any WindowSystem,
                             attempts: Int = 2) -> Bool {
        for _ in 0..<attempts {
            if window.minimized {
                _ = system.unminimize(pid: window.pid, title: window.title)
            }
            _ = system.raise(pid: window.pid, title: window.title)
            _ = system.makeMain(pid: window.pid, title: window.title)
            _ = system.activate(pid: window.pid, allWindows: false)
            system.settle()
            if system.frontmostPID() == window.pid,
               system.focusedWindowTitle(pid: window.pid) == window.title {
                return true
            }
        }
        return false
    }
}
