import Foundation

/// Thread-safe record of which browsers refused Apple Events — the ONLY
/// place a TCC Automation denial becomes visible. Silent scan failures
/// have bitten twice; never again.
final class AutomationStatus: @unchecked Sendable {
    static let shared = AutomationStatus()
    private let lock = NSLock()
    private var denied: Set<String> = []

    func set(_ target: String, denied isDenied: Bool) {
        lock.withLock {
            if isDenied { denied.insert(target) } else { denied.remove(target) }
        }
    }

    var deniedTargets: [String] {
        lock.withLock { denied.sorted() }
    }
}

/// Runs AppleScript via /usr/bin/osascript as a child process.
///
/// Why not NSAppleScript: it is documented main-thread-only, has no timeout,
/// and a hung script would freeze the app. A child process is isolatable and
/// killable. TCC still attributes the Apple Events to JumpCall because the
/// responsible process for our children is the bundle-launched app itself.
enum ScriptRunner {
    @discardableResult
    static func run(_ script: String, timeout: TimeInterval = 5, permissionTarget: String? = nil) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        let done = DispatchSemaphore(value: 0)
        proc.terminationHandler = { _ in done.signal() }
        do {
            try proc.run()
        } catch {
            return nil
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            proc.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errText = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if let permissionTarget {
            // -1743 = errAEEventNotPermitted: the user (or a stale TCC grant
            // after a rebuild) is blocking Apple Events to this app.
            let deniedNow = errText.contains("-1743") || errText.contains("not allowed")
            AutomationStatus.shared.set(permissionTarget, denied: deniedNow)
        }
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
