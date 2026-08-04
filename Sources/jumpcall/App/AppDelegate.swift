import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: DetectionEngine?
    private var statusController: StatusItemController?
    private var coordinator: JumpCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.load()
        let registry = MatcherRegistry(config: config)
        let engine = DetectionEngine(config: config, registry: registry)
        let statusController = StatusItemController(engine: engine, config: config)
        let coordinator = JumpCoordinator(
            engine: engine, registry: registry, statusController: statusController)

        statusController.onJumpRequested = { coordinator.jumpToLiveCall() }
        engine.onStateChange = { state in
            statusController.update(state: state)
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in engine.setSystemAsleep(true) }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in engine.setSystemAsleep(false) }

        engine.start()

        self.engine = engine
        self.statusController = statusController
        self.coordinator = coordinator
    }
}
