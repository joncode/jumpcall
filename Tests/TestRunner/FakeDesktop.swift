import Foundation
import JumpCallKit

/// A tiny simulated window server for jump tests. Models just enough of
/// macOS to reproduce "jumpcall switched to the right Space but the call
/// window is still hidden behind another window":
///
/// - one global z-order (front first); all windows are the same size, so
///   any visible window above another on the same Space fully covers it
/// - Spaces, each on a display; each display shows one Space at a time
/// - activating an app brings its key window (or all its windows) forward
///   and switches that display to the key window's Space
/// - AXRaise only reorders within the app; it does not switch Spaces
/// - quirks: Chrome's `set index of window` may not move the real window
///   (`setIndexRaises`), and activation may hand focus back to the old key
///   window (`restoreKeyWindow` / `restoreCount`)
final class FakeDesktop: WindowSystem, @unchecked Sendable {
    struct Win {
        let pid: pid_t
        let title: String
        var minimized = false
        var space = 1
        /// Position in the browser's AppleScript `windows` list, if scriptable.
        var scriptIndex: Int? = nil
        /// Active tab title as AppleScript reports it (AX title may add a
        /// profile suffix, e.g. "Meet – abc-defg-hij - Work").
        var tabTitle: String? = nil
    }

    var z: [Win] = []
    var spaceDisplay: [Int: Int] = [:]   // Space -> display (default display 1)
    var visibleSpace: [Int: Int] = [:]   // display -> Space showing
    var front: pid_t?
    var bundles: [String: [pid_t]] = [:]

    var setIndexRaises = false
    var accessibilityGranted = true
    var restoreKeyWindow: String?
    var restoreCount = 0

    private(set) var activations: [(pid: pid_t, allWindows: Bool)] = []

    // MARK: Helpers

    private func display(of space: Int) -> Int { spaceDisplay[space] ?? 1 }
    private func show(_ space: Int) { visibleSpace[display(of: space)] = space }
    private func index(_ pid: pid_t, _ title: String) -> Int? {
        z.firstIndex { $0.pid == pid && $0.title == title }
    }

    /// Move a window to the front of its own app's windows.
    private func raiseWithinApp(_ i: Int) {
        let w = z.remove(at: i)
        let slot = z.firstIndex { $0.pid == w.pid } ?? z.count
        z.insert(w, at: min(slot, z.count))
    }

    private func toTop(_ i: Int) {
        let w = z.remove(at: i)
        z.insert(w, at: 0)
    }

    /// The user can see the window: frontmost app owns it, its Space is on
    /// screen, it isn't minimized, and nothing on that Space is above it.
    func userSees(_ title: String) -> Bool {
        guard let i = z.firstIndex(where: { $0.title == title }) else { return false }
        let w = z[i]
        guard !w.minimized, front == w.pid,
              visibleSpace[display(of: w.space)] == w.space else { return false }
        return !z[..<i].contains { !$0.minimized && $0.space == w.space }
    }

    // MARK: WindowSystem

    func runScript(_ source: String) -> String? {
        guard let m = source.firstMatch(of: /window (\d+)/), let n = Int(m.1),
              let i = z.firstIndex(where: { $0.scriptIndex == n }) else { return nil }
        let w = z[i]
        if setIndexRaises { raiseWithinApp(i) }
        // The jump script ends with `activate`.
        activate(w.pid, allWindows: false, quirks: false)
        return w.tabTitle ?? w.title
    }

    func pids(bundleID: String) -> [pid_t] { bundles[bundleID] ?? [] }

    func activate(pid: pid_t, allWindows: Bool) -> Bool {
        activations.append((pid, allWindows))
        activate(pid, allWindows: allWindows, quirks: true)
        return true
    }

    private func activate(_ pid: pid_t, allWindows: Bool, quirks: Bool) {
        front = pid
        if allWindows {
            let mine = z.filter { $0.pid == pid && !$0.minimized }
            z.removeAll { $0.pid == pid && !$0.minimized }
            z.insert(contentsOf: mine, at: 0)
        } else if let k = z.firstIndex(where: { $0.pid == pid && !$0.minimized }) {
            toTop(k)
        }
        if quirks, restoreCount > 0, let title = restoreKeyWindow, let r = index(pid, title) {
            restoreCount -= 1
            toTop(r)
        }
        if let key = z.first(where: { $0.pid == pid && !$0.minimized }) { show(key.space) }
    }

    func windows(pid: pid_t) -> [WindowRef] {
        guard accessibilityGranted else { return [] }
        return z.filter { $0.pid == pid }.map { WindowRef(pid: pid, title: $0.title, minimized: $0.minimized) }
    }

    func unminimize(pid: pid_t, title: String) -> Bool {
        guard accessibilityGranted, let i = index(pid, title) else { return false }
        z[i].minimized = false
        raiseWithinApp(i)
        return true
    }

    /// Mirrors AXWindowProbe.raise: un-minimize, then AXRaise.
    func raise(pid: pid_t, title: String) -> Bool {
        guard accessibilityGranted, let i = index(pid, title) else { return false }
        z[i].minimized = false
        raiseWithinApp(i)
        return true
    }

    func makeMain(pid: pid_t, title: String) -> Bool {
        guard accessibilityGranted, let i = index(pid, title), !z[i].minimized else { return false }
        raiseWithinApp(i)
        return true
    }

    func frontmostPID() -> pid_t? { front }

    func focusedWindowTitle(pid: pid_t) -> String? {
        guard accessibilityGranted else { return nil }
        return z.first { $0.pid == pid && !$0.minimized }?.title
    }

    func settle() {}
}
