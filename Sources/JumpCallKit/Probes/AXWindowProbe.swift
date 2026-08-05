import ApplicationServices
import Foundation

/// Raises browser windows via the Accessibility API. Unlike AppleScript,
/// AX sees ALL of a browser's windows — including other Chrome profiles,
/// incognito windows, and PWAs, which Chrome hides from its scripting
/// dictionary. Requires the Accessibility permission the hotkey already
/// uses; callers must degrade gracefully when it's absent.
public enum AXWindowProbe {
    /// True if this window title looks like an active video call.
    public static func titleLooksLikeCall(_ title: String) -> Bool {
        // A Meet meeting code in the title is the strongest signal.
        if title.contains(/[a-z]{3}-[a-z]{4}-[a-z]{3}/) { return true }
        let markers = [
            "Meet – ", "Meet - ", "– Meet", "- Meet",
            "Microsoft Teams", "Webex", "Zoom Meeting",
        ]
        return markers.contains { title.contains($0) }
    }

    /// Find a call-looking window owned by `pid` and raise it.
    static func raiseCallWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String else { continue }
            if titleLooksLikeCall(title) {
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                return true
            }
        }
        return false
    }
}
