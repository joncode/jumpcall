import AppKit
import Foundation

public struct Browser: Sendable {
    public let id: String
    public let appName: String
    public let bundleID: String
    public let isChromium: Bool

    /// Browsers jumpcall knows how to script. Chromium-family browsers all
    /// share Chrome's AppleScript dictionary. Firefox is absent because it
    /// has no AppleScript tab access at all — documented limitation.
    public static let known: [String: Browser] = [
        "safari": Browser(id: "safari", appName: "Safari", bundleID: "com.apple.Safari", isChromium: false),
        "chrome": Browser(id: "chrome", appName: "Google Chrome", bundleID: "com.google.Chrome", isChromium: true),
        "brave": Browser(id: "brave", appName: "Brave Browser", bundleID: "com.brave.Browser", isChromium: true),
        "edge": Browser(id: "edge", appName: "Microsoft Edge", bundleID: "com.microsoft.edgemac", isChromium: true),
        "arc": Browser(id: "arc", appName: "Arc", bundleID: "company.thebrowser.Browser", isChromium: true),
    ]
}

public struct MeetMatcher: PlatformMatcher {
    public let id = "meet"
    public let displayName = "Google Meet"
    let browsers: [Browser]

    public func detect() -> CallHandle? {
        for browser in browsers {
            // Never send Apple Events to a browser that isn't running —
            // that would launch it (and prompt for permission pointlessly).
            guard onMain({ ProcessProbe.isAppRunning(bundleID: browser.bundleID) }) else { continue }
            if let handle = probe(browser) { return handle }
        }
        // The tab scan is blind to other Chrome profiles, incognito windows,
        // and PWAs (Chrome hides them from AppleScript). But if a browser is
        // actively using the microphone, there IS a live web call somewhere
        // in it — report it, and let jump() find the window via AX instead.
        return micFallback()
    }

    private func micFallback() -> CallHandle? {
        let micUsers = AudioInputProbe.processesUsingMicrophone()
        for browser in browsers where browser.isChromium {
            guard onMain({ ProcessProbe.isAppRunning(bundleID: browser.bundleID) }) else { continue }
            if micUsers.contains(where: { $0.bundleID.hasPrefix(browser.bundleID) }) {
                return CallHandle(
                    platformID: id,
                    displayName: "Web call — \(browser.appName)",
                    detail: "window hidden from tab scan (other profile / incognito / PWA)",
                    activateBundleID: browser.bundleID,
                    browserID: browser.id,
                    windowIndex: nil,
                    tabIndex: nil)
            }
        }
        return nil
    }

    private func probe(_ browser: Browser) -> CallHandle? {
        guard let output = ScriptRunner.run(Self.listScript(for: browser)),
              !output.isEmpty else { return nil }
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count == 3,
                  let window = Int(parts[0]),
                  let tab = Int(parts[1]) else { continue }
            let url = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard Self.isMeetingURL(url) else { continue }
            return CallHandle(
                platformID: id,
                displayName: "Google Meet — \(browser.appName)",
                detail: url,
                activateBundleID: browser.bundleID,
                browserID: browser.id,
                windowIndex: window,
                tabIndex: tab)
        }
        return nil
    }

    public func jump(_ handle: CallHandle) -> Bool {
        guard let browser = browsers.first(where: { $0.id == handle.browserID }) else { return false }
        guard let window = handle.windowIndex, let tab = handle.tabIndex else {
            return jumpToHiddenWindow(browser)
        }
        let ok = ScriptRunner.run(Self.jumpScript(for: browser, window: window, tab: tab)) != nil
        // Belt and suspenders for cross-Space / full-screen switching.
        onMain {
            ProcessProbe.runningApp(bundleID: browser.bundleID)?
                .activate(options: [.activateAllWindows])
        }
        return ok
    }

    /// Mic-fallback path: the call window is invisible to AppleScript, so
    /// raise it via Accessibility (which sees all profiles/incognito/PWAs).
    /// If AX finds nothing (or permission is missing), activating the
    /// browser still lands the user one window-switch away.
    private func jumpToHiddenWindow(_ browser: Browser) -> Bool {
        onMain {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            let raised = apps.contains { AXWindowProbe.raiseCallWindow(pid: $0.processIdentifier) }
            let activated = apps.first?.activate(options: [.activateAllWindows]) ?? false
            return raised || activated
        }
    }

    /// Real meetings look like meet.google.com/abc-defg-hij (plus optional
    /// query/fragment) or meet.google.com/lookup/<slug> for edu accounts.
    /// The landing page, /new, etc. must NOT count as a live call.
    public static func isMeetingURL(_ url: String) -> Bool {
        let code = /https:\/\/meet\.google\.com\/[a-z]{3}-[a-z]{4}-[a-z]{3}([\/?#].*)?/
        let lookup = /https:\/\/meet\.google\.com\/lookup\/[A-Za-z0-9-]+([\/?#].*)?/
        return url.wholeMatch(of: code) != nil || url.wholeMatch(of: lookup) != nil
    }

    static func listScript(for browser: Browser) -> String {
        // Same shape for both dictionaries: Safari and Chromium each expose
        // `URL of tab i of window w`. Output: "window|tab|url" per line.
        """
        set out to ""
        tell application "\(browser.appName)"
        	set winCount to count of windows
        	repeat with wi from 1 to winCount
        		try
        			set tabCount to count of tabs of window wi
        			repeat with ti from 1 to tabCount
        				try
        					set u to URL of tab ti of window wi
        					if u contains "meet.google.com" then
        						set out to out & wi & "|" & ti & "|" & u & linefeed
        					end if
        				end try
        			end repeat
        		end try
        	end repeat
        end tell
        return out
        """
    }

    static func jumpScript(for browser: Browser, window: Int, tab: Int) -> String {
        if browser.isChromium {
            return """
            tell application "\(browser.appName)"
            	set active tab index of window \(window) to \(tab)
            	set index of window \(window) to 1
            	activate
            end tell
            """
        }
        return """
        tell application "\(browser.appName)"
        	tell window \(window) to set current tab to tab \(tab)
        	set index of window \(window) to 1
        	activate
        end tell
        """
    }
}
