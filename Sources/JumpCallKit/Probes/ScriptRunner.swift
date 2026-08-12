import Foundation

private final class ScriptRunnerSemaphore: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    func signal() { semaphore.signal() }
    func wait(timeout: DispatchTime) -> DispatchTimeoutResult { semaphore.wait(timeout: timeout) }
}

/// Runs AppleScript via /usr/bin/osascript as a child process.
///
/// Why not NSAppleScript: it is documented main-thread-only, has no timeout,
/// and a hung script would freeze the app. A child process is isolatable and
/// killable. TCC still attributes the Apple Events to JumpCall because the
/// responsible process for our children is the bundle-launched app itself.
enum ScriptRunner {
    @discardableResult
    static func run(_ script: String, timeout: TimeInterval = 5) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-e", script]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe() // discard; a denied Automation prompt is not our stdout
        let done = ScriptRunnerSemaphore()
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
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
