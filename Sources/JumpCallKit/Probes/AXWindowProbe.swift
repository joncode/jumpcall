import ApplicationServices
import Foundation

public struct AXWindowInfo: Sendable, Equatable {
    public let pid: pid_t
    public let title: String
    public let area: Double
    public let minimized: Bool

    public init(pid: pid_t, title: String, area: Double, minimized: Bool) {
        self.pid = pid
        self.title = title
        self.area = area
        self.minimized = minimized
    }
}

/// Reads and raises browser windows via the Accessibility API. Unlike
/// AppleScript, AX sees every open window of a browser — all Chrome
/// profiles, incognito windows, and PWAs alike — so window matching here
/// is profile-agnostic by construction. Requires the Accessibility
/// permission the hotkey already uses; callers degrade gracefully.
public enum AXWindowProbe {
    /// True if this window title looks like an active video call.
    public static func titleLooksLikeCall(_ title: String) -> Bool {
        titleMatchStrength(title) > 0
    }

    /// 2 = contains a Meet meeting code (strongest), 1 = platform marker, 0 = no.
    public static func titleMatchStrength(_ title: String) -> Int {
        let meetCodePattern = "[a-z]{3}-[a-z]{4}-[a-z]{3}"
        if let regex = try? NSRegularExpression(pattern: meetCodePattern),
           regex.firstMatch(in: title, options: [], range: NSRange(title.startIndex..., in: title)) != nil {
            return 2
        }
        let markers = [
            "Meet – ", "Meet - ", "– Meet", "- Meet",
            "Microsoft Teams", "Webex", "Zoom Meeting",
        ]
        return markers.contains { title.contains($0) } ? 1 : 0
    }

    /// Best call-looking window among ALL open windows: meeting-code match
    /// beats marker match; ties go to the larger window.
    public static func pickCallWindow(from windows: [AXWindowInfo]) -> AXWindowInfo? {
        windows
            .map { (window: $0, strength: titleMatchStrength($0.title)) }
            .filter { $0.strength > 0 }
            .max { ($0.strength, $0.window.area) < ($1.strength, $1.window.area) }?
            .window
    }

    /// All open windows across these processes (e.g. every running process
    /// of a browser bundle id).
    public static func allWindows(pids: [pid_t]) -> [AXWindowInfo] {
        pids.flatMap { windows(pid: $0) }
    }

    /// All windows of one process: title, size, minimized state.
    public static func windows(pid: pid_t) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.map { window in
            AXWindowInfo(
                pid: pid,
                title: stringAttribute(window, kAXTitleAttribute) ?? "",
                area: windowArea(window),
                minimized: boolAttribute(window, kAXMinimizedAttribute))
        }
    }

    /// Find the window with this exact title again, un-minimize, raise.
    public static func raise(windowTitled title: String, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return false }
        for window in windows where stringAttribute(window, kAXTitleAttribute) == title {
            if boolAttribute(window, kAXMinimizedAttribute) {
                AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            }
            return AXUIElementPerformAction(window, kAXRaiseAction as CFString) == .success
        }
        return false
    }

    // MARK: - Attribute helpers

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private static func boolAttribute(_ element: AXUIElement, _ name: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }

    private static func windowArea(_ window: AXUIElement) -> Double {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value else { return 0 }
        var size = CGSize.zero
        guard CFGetTypeID(axValue) == AXValueGetTypeID(),
              AXValueGetValue(axValue as! AXValue, .cgSize, &size) else { return 0 }
        return Double(size.width * size.height)
    }
}
