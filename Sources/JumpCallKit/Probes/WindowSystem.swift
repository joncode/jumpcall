import AppKit
import ApplicationServices
import Foundation

/// A browser window as the jump logic sees it.
public struct WindowRef: Sendable, Equatable {
    public let pid: pid_t
    public let title: String
    public let minimized: Bool

    public init(pid: pid_t, title: String, minimized: Bool) {
        self.pid = pid
        self.title = title
        self.minimized = minimized
    }
}

/// The OS operations a jump needs. `LiveWindowSystem` wraps AppleScript,
/// NSRunningApplication and Accessibility; tests substitute a simulated
/// window server so z-order bugs ("the call window is hidden behind another
/// window of the same size") can be reproduced without a real desktop.
public protocol WindowSystem: Sendable {
    func runScript(_ source: String) -> String?
    func pids(bundleID: String) -> [pid_t]
    func activate(pid: pid_t, allWindows: Bool) -> Bool
    func windows(pid: pid_t) -> [WindowRef]
    func unminimize(pid: pid_t, title: String) -> Bool
    func raise(pid: pid_t, title: String) -> Bool
    func makeMain(pid: pid_t, title: String) -> Bool
    func frontmostPID() -> pid_t?
    func focusedWindowTitle(pid: pid_t) -> String?
    /// Give the window server a moment to apply activation before verifying.
    func settle()
}

public struct LiveWindowSystem: WindowSystem {
    public init() {}

    public func runScript(_ source: String) -> String? { ScriptRunner.run(source) }

    public func pids(bundleID: String) -> [pid_t] {
        onMain {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .map(\.processIdentifier)
        }
    }

    public func activate(pid: pid_t, allWindows: Bool) -> Bool {
        onMain {
            NSRunningApplication(processIdentifier: pid)?
                .activate(options: allWindows ? [.activateAllWindows] : []) ?? false
        }
    }

    public func windows(pid: pid_t) -> [WindowRef] {
        onMain {
            AXWindowProbe.windows(pid: pid).map {
                WindowRef(pid: $0.pid, title: $0.title, minimized: $0.minimized)
            }
        }
    }

    public func unminimize(pid: pid_t, title: String) -> Bool {
        onMain { AXWindowProbe.setMinimized(false, windowTitled: title, pid: pid) }
    }

    public func raise(pid: pid_t, title: String) -> Bool {
        onMain { AXWindowProbe.raise(windowTitled: title, pid: pid) }
    }

    public func makeMain(pid: pid_t, title: String) -> Bool {
        onMain { AXWindowProbe.makeMain(windowTitled: title, pid: pid) }
    }

    public func frontmostPID() -> pid_t? {
        onMain { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    }

    public func focusedWindowTitle(pid: pid_t) -> String? {
        onMain { AXWindowProbe.focusedWindowTitle(pid: pid) }
    }

    public func settle() { Thread.sleep(forTimeInterval: 0.15) }
}
