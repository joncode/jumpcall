import AppKit
import Darwin
import Foundation

/// Run a body on the main actor from any thread, synchronously.
/// AppKit types like NSRunningApplication are main-actor isolated in the
/// Swift 6 overlay; detection runs on a background queue, so probes hop over.
@discardableResult
func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
        return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync {
        MainActor.assumeIsolated(body)
    }
}

enum ProcessProbe {
    /// True if a process with this exact name exists (any user). No TCC
    /// permission needed. This is how Zoom meetings are detected: zoom.us
    /// spawns a `CptHost` child process for the duration of a meeting.
    static func isProcessRunning(named target: String) -> Bool {
        var capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return false }
        capacity += 32 // headroom for processes spawned between the two calls
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let filled = proc_listallpids(&pids, capacity * Int32(MemoryLayout<pid_t>.size))
        guard filled > 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN))
        for pid in pids.prefix(Int(filled)) where pid > 0 {
            let len = buf.withUnsafeMutableBytes { raw in
                proc_name(pid, raw.baseAddress, UInt32(raw.count))
            }
            if len > 0, decode(buf) == target {
                return true
            }
        }
        return false
    }

    static func processName(for pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXCOMLEN))
        let len = buf.withUnsafeMutableBytes { raw in
            proc_name(pid, raw.baseAddress, UInt32(raw.count))
        }
        guard len > 0 else { return nil }
        return decode(buf)
    }

    private static func decode(_ buf: [CChar]) -> String {
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    @MainActor
    static func runningApp(bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    @MainActor
    static func runningApp(bundleIDPrefix: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier?.hasPrefix(bundleIDPrefix) == true
        }
    }

    @MainActor
    static func isAppRunning(bundleID: String) -> Bool {
        runningApp(bundleID: bundleID) != nil
    }
}
