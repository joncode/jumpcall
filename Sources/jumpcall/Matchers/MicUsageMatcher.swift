import AppKit
import Foundation

/// Generic "this app has the microphone open" matcher. Teams, Webex and
/// FaceTime are pure config instances of this — and users can add more
/// platforms in config.json without any code.
struct MicUsageMatcher: PlatformMatcher {
    let config: MicMatcherConfig

    var id: String { config.id }
    var displayName: String { config.displayName }

    func detect() -> CallHandle? {
        let live = AudioInputProbe.processesUsingMicrophone()
        guard let hit = live.first(where: { process in
            config.bundlePrefixes.contains { process.bundleID.hasPrefix($0) }
        }) else { return nil }
        if let requiredPrefix = config.requireAppRunningPrefix {
            guard onMain({ ProcessProbe.runningApp(bundleIDPrefix: requiredPrefix) != nil }) else {
                return nil
            }
        }
        return CallHandle(
            platformID: id,
            displayName: "\(displayName) call",
            detail: hit.bundleID.isEmpty ? ProcessProbe.processName(for: hit.pid) : hit.bundleID,
            activateBundleID: config.activateBundleID ?? hit.bundleID)
    }

    func jump(_ handle: CallHandle) -> Bool {
        onMain {
            var app = handle.activateBundleID.flatMap { ProcessProbe.runningApp(bundleID: $0) }
            if app == nil {
                app = config.bundlePrefixes.lazy
                    .compactMap { ProcessProbe.runningApp(bundleIDPrefix: $0) }
                    .first
            }
            return app?.activate(options: [.activateAllWindows]) ?? false
        }
    }
}
