import AppKit
import Foundation

/// The single entry point for "take me to my call", used by the status-item
/// click, the global hotkey, and the `jumpcall jump` CLI verb.
@MainActor
final class JumpCoordinator {
    private let engine: DetectionEngine
    private let registry: MatcherRegistry
    private weak var statusController: StatusItemController?

    /// Frontmost app captured just before the last jump — the boomerang's
    /// return destination.
    private var originPID: pid_t?

    init(engine: DetectionEngine, registry: MatcherRegistry, statusController: StatusItemController?) {
        self.engine = engine
        self.registry = registry
        self.statusController = statusController
    }

    var canReturn: Bool {
        guard let originPID,
              let app = NSRunningApplication(processIdentifier: originPID) else { return false }
        return !app.isTerminated
    }

    func jumpToLiveCall() {
        engine.verifyNow { [weak self] state in
            guard let self else { return }
            switch state {
            case .live(let handle):
                self.perform(handle)
            case .none:
                self.statusController?.showNoCall()
            }
        }
    }

    /// Icon click: away from the call → jump; already looking at the call →
    /// the menu (with "Return to Previous App") instead of a useless no-op jump.
    func primaryClick() {
        engine.verifyNow { [weak self] state in
            guard let self else { return }
            switch state {
            case .live(let handle):
                if CallScreen.isOn(handle) {
                    self.statusController?.showCallScreenMenu(canReturn: self.canReturn)
                } else {
                    self.perform(handle)
                }
            case .none:
                self.statusController?.showNoCall()
            }
        }
    }

    /// Hotkey behavior: away from the call → jump to it; already looking at
    /// it → bounce back to whatever app you were in before the last jump.
    func toggleJumpToLiveCall() {
        engine.verifyNow { [weak self] state in
            guard let self else { return }
            switch state {
            case .live(let handle):
                if CallScreen.isOn(handle) {
                    self.returnToOrigin()
                } else {
                    self.perform(handle)
                }
            case .none:
                break // hotkey only fires while live; nothing sensible to do
            }
        }
    }

    func returnToOrigin() {
        guard let originPID,
              let app = NSRunningApplication(processIdentifier: originPID),
              !app.isTerminated else { return }
        app.activate(options: [.activateAllWindows])
    }

    private func perform(_ handle: CallHandle) {
        guard let matcher = registry.matcher(id: handle.platformID) else { return }
        // Remember where the user was so the hotkey (or menu) can bounce back.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != handle.activateBundleID {
            originPID = front.processIdentifier
        }
        // AppleScript-backed jumps block for an osascript round-trip;
        // keep that off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = matcher.jump(handle)
        }
    }
}
