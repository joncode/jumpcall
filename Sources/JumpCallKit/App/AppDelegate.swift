import AppKit

/// Sendable box so sleep/wake observers always reach the CURRENT engine,
/// which is rebuilt whenever settings change.
private final class EngineBox: @unchecked Sendable {
    var engine: DetectionEngine?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let engineBox = EngineBox()
    private var engine: DetectionEngine?
    private var registry: MatcherRegistry?
    private var statusController: StatusItemController?
    private var coordinator: JumpCoordinator?
    private var hotkey: HotkeyManager?
    private let settings = SettingsWindowController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let config = ConfigStore.load()
        let statusController = StatusItemController(config: config)
        self.statusController = statusController

        statusController.onOpenSettings = { [weak self] in
            guard let self else { return }
            self.settings.show(config: ConfigStore.load())
        }
        settings.onConfigChange = { [weak self] cfg in
            try? ConfigStore.write(cfg)
            self?.apply(config: cfg)
        }

        let center = NSWorkspace.shared.notificationCenter
        let box = engineBox
        center.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { _ in box.engine?.setSystemAsleep(true) }
        center.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in box.engine?.setSystemAsleep(false) }

        apply(config: config)
    }

    /// Build (or rebuild, on a settings change) the whole detection stack.
    private func apply(config: Config) {
        engine?.stop()
        hotkey?.stop()

        guard let statusController else { return }
        let registry = MatcherRegistry(config: config)
        let engine = DetectionEngine(config: config, registry: registry)
        let coordinator = JumpCoordinator(
            engine: engine, registry: registry, statusController: statusController)

        statusController.engine = engine
        statusController.apply(config: config)
        statusController.onJumpRequested = { coordinator.jumpToLiveCall() }
        engine.onStateChange = { state in
            statusController.update(state: state)
        }

        if config.hotkeyEnabled, let spec = KeySpec.parse(config.hotkey) ?? .some(.default) {
            let hotkey = HotkeyManager(
                spec: spec,
                isLive: { engine.cachedState.isLive },
                onTrigger: {
                    Task { @MainActor in coordinator.jumpToLiveCall() }
                })
            hotkey.startWhenPermitted(promptOnce: !HotkeyManager.hasAccessibilityPermission)
            statusController.hotkey = hotkey
            self.hotkey = hotkey
        } else {
            statusController.hotkey = nil
            self.hotkey = nil
        }

        engine.start()

        self.engine = engine
        self.registry = registry
        self.coordinator = coordinator
        engineBox.engine = engine
    }
}
