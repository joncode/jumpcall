import AppKit
import Foundation

public struct Browser: Sendable {
    public let id: String
    public let appName: String
    public let bundleID: String
    public let isChromium: Bool
    /// Bundle-ID prefixes whose mic usage counts as this browser's.
    /// Chromium helpers share the app's prefix, but Safari captures audio in
    /// com.apple.WebKit.GPU — no com.apple.Safari prefix — so without the
    /// extra entry Safari's mic state is invisible to mic-priority ordering.
    public let micBundlePrefixes: [String]

    init(id: String, appName: String, bundleID: String, isChromium: Bool,
         micBundlePrefixes: [String]? = nil) {
        self.id = id
        self.appName = appName
        self.bundleID = bundleID
        self.isChromium = isChromium
        self.micBundlePrefixes = micBundlePrefixes ?? [bundleID]
    }

    /// Browsers jumpcall knows how to script. Chromium-family browsers all
    /// share Chrome's AppleScript dictionary. Firefox is absent because it
    /// has no AppleScript tab access at all — documented limitation.
    public static let known: [String: Browser] = [
        "safari": Browser(id: "safari", appName: "Safari", bundleID: "com.apple.Safari", isChromium: false,
                          micBundlePrefixes: ["com.apple.Safari", "com.apple.WebKit."]),
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

    /// True when any of `micBundleIDs` belongs to this browser.
    public static func holdsMic(_ browser: Browser, micBundleIDs: [String]) -> Bool {
        browser.micBundlePrefixes.contains { prefix in
            micBundleIDs.contains { $0.hasPrefix(prefix) }
        }
    }

    /// Browsers actively holding the microphone are scanned first: a live
    /// call always outranks a lobby/landing page open in another browser
    /// (their URLs are indistinguishable — meet.google.com/xxx-yyyy-zzz is
    /// the same joined or not, so the mic is the tiebreaker).
    public static func orderByMicPriority(_ browsers: [Browser], micBundleIDs: [String]) -> [Browser] {
        browsers.filter { holdsMic($0, micBundleIDs: micBundleIDs) }
            + browsers.filter { !holdsMic($0, micBundleIDs: micBundleIDs) }
    }

    public func detect() -> CallHandle? {
        let micBundleIDs = AudioInputProbe.processesUsingMicrophone().map(\.bundleID)
        let micHolders = browsers.filter { Self.holdsMic($0, micBundleIDs: micBundleIDs) }
        let rest = browsers.filter { !Self.holdsMic($0, micBundleIDs: micBundleIDs) }

        // A browser holding the mic is where the call actually is. Exhaust it
        // completely — tab scan, then the profile-agnostic AX window scan —
        // before trusting a URL-only hit elsewhere: a lobby/green-room tab in
        // an idle browser must never outrank the browser transmitting audio
        // (e.g. the call lives in a Chrome profile AppleScript can't see).
        for browser in micHolders {
            guard onMain({ ProcessProbe.isAppRunning(bundleID: browser.bundleID) }) else { continue }
            if let handle = probe(browser) { return handle }
            if let handle = axWindowScan(browser) { return handle }
        }
        for browser in rest {
            // Never send Apple Events to a browser that isn't running —
            // that would launch it (and prompt for permission pointlessly).
            guard onMain({ ProcessProbe.isAppRunning(bundleID: browser.bundleID) }) else { continue }
            if let handle = probe(browser) { return handle }
        }
        // The tab scan only sees what the browser's scripting API exposes —
        // Chrome hides other profiles, incognito windows, and PWAs from it.
        // The Accessibility scan is profile-agnostic: it checks every open
        // window of every running browser and matches call-looking titles.
        for browser in rest {
            if let handle = axWindowScan(browser) { return handle }
        }
        // Last resort: a browser is actively using the microphone, so a web
        // call exists even though no window could be identified.
        return micFallback()
    }

    private func axWindowScan(_ browser: Browser) -> CallHandle? {
        let pids = onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
                .map(\.processIdentifier)
        }
        guard !pids.isEmpty else { return nil }
        let windows = onMain { AXWindowProbe.allWindows(pids: pids) }
        guard let window = AXWindowProbe.pickCallWindow(from: windows) else { return nil }
        return CallHandle(
            platformID: id,
            displayName: "Web call — \(browser.appName)",
            detail: window.title,
            activateBundleID: browser.bundleID,
            browserID: browser.id,
            windowIndex: nil,
            tabIndex: nil,
            axWindowTitle: window.title)
    }

    private func micFallback() -> CallHandle? {
        let micBundleIDs = AudioInputProbe.processesUsingMicrophone().map(\.bundleID)
        for browser in browsers {
            guard onMain({ ProcessProbe.isAppRunning(bundleID: browser.bundleID) }) else { continue }
            if Self.holdsMic(browser, micBundleIDs: micBundleIDs) {
                return CallHandle(
                    platformID: id,
                    displayName: "Web call — \(browser.appName)",
                    detail: "call window could not be identified by title",
                    activateBundleID: browser.bundleID,
                    browserID: browser.id,
                    windowIndex: nil,
                    tabIndex: nil)
            }
        }
        return nil
    }

    private func probe(_ browser: Browser) -> CallHandle? {
        guard let output = ScriptRunner.run(
                  Self.listScript(for: browser), permissionTarget: browser.appName),
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
            return jumpToHiddenWindow(browser, title: handle.axWindowTitle)
        }
        let ok = ScriptRunner.run(Self.jumpScript(for: browser, window: window, tab: tab)) != nil
        // Belt and suspenders for cross-Space / full-screen switching.
        onMain {
            ProcessProbe.runningApp(bundleID: browser.bundleID)?
                .activate(options: [.activateAllWindows])
        }
        return ok
    }

    /// AX path: raise the exact window found at detect time (works across
    /// all profiles/incognito/PWAs). Re-verify on click means the title is
    /// at most a moment old. Activate WITHOUT .activateAllWindows so other
    /// windows don't pile on top of the raised one; if no title was found
    /// (mic-only fallback), activate everything — one window-switch away.
    private func jumpToHiddenWindow(_ browser: Browser, title: String?) -> Bool {
        onMain {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleID)
            guard let title else {
                return apps.first?.activate(options: [.activateAllWindows]) ?? false
            }
            let raised = apps.contains { AXWindowProbe.raise(windowTitled: title, pid: $0.processIdentifier) }
            let activated = apps.first?.activate(options: []) ?? false
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
