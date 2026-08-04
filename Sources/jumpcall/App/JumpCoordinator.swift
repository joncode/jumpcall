import AppKit
import Foundation

/// The single entry point for "take me to my call". Used by the status-item
/// click and the `jumpcall jump` CLI verb; a future global hotkey (v2) is
/// just a third caller.
@MainActor
final class JumpCoordinator {
    private let engine: DetectionEngine
    private let registry: MatcherRegistry
    private weak var statusController: StatusItemController?

    init(engine: DetectionEngine, registry: MatcherRegistry, statusController: StatusItemController?) {
        self.engine = engine
        self.registry = registry
        self.statusController = statusController
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

    private func perform(_ handle: CallHandle) {
        guard let matcher = registry.matcher(id: handle.platformID) else { return }
        // AppleScript-backed jumps block for an osascript round-trip;
        // keep that off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            _ = matcher.jump(handle)
        }
    }
}
