import AppKit
import Foundation

struct ZoomMatcher: PlatformMatcher {
    let id = "zoom"
    let displayName = "Zoom"
    static let bundleID = "us.zoom.xos"

    func detect() -> CallHandle? {
        // CptHost exists only while a meeting is running. The mic-usage check
        // is a regression guard in case Zoom ever renames its helper.
        let inMeeting = ProcessProbe.isProcessRunning(named: "CptHost")
            || AudioInputProbe.processesUsingMicrophone()
                .contains { $0.bundleID.hasPrefix(Self.bundleID) }
        guard inMeeting else { return nil }
        guard onMain({ ProcessProbe.isAppRunning(bundleID: Self.bundleID) }) else { return nil }
        return CallHandle(
            platformID: id,
            displayName: "Zoom meeting",
            activateBundleID: Self.bundleID)
    }

    func jump(_ handle: CallHandle) -> Bool {
        onMain {
            guard let app = ProcessProbe.runningApp(bundleID: Self.bundleID) else { return false }
            return app.activate(options: [.activateAllWindows])
        }
    }
}
