import AppKit

@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let engine: DetectionEngine
    private let config: Config
    private(set) var state: CallState = .none
    private var paused = false

    var onJumpRequested: (() -> Void)?

    init(engine: DetectionEngine, config: Config) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.engine = engine
        self.config = config
        super.init()
        if let button = statusItem.button {
            button.image = Self.idleImage()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "JumpCall — no live call"
        }
    }

    func update(state: CallState) {
        self.state = state
        guard let button = statusItem.button else { return }
        switch state {
        case .live(let handle):
            button.image = Self.liveImage(style: config.iconStyle)
            button.appearsDisabled = false
            button.toolTip = "\(handle.displayName) — click to jump"
        case .none:
            button.image = Self.idleImage()
            button.appearsDisabled = paused
            button.toolTip = paused ? "JumpCall — detection paused" : "JumpCall — no live call"
        }
    }

    /// Click-time verification found no call after all: reflect it, tell the user.
    func showNoCall() {
        update(state: .none)
        showMenu()
    }

    // MARK: - Click handling

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if !isRightClick, state.isLive {
            onJumpRequested?()
        } else {
            showMenu()
        }
    }

    // The status item has no permanent menu (that would swallow left-clicks);
    // it is attached transiently, shown, then detached.
    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let title: String
        if case .live(let handle) = state {
            title = "Live: \(handle.displayName)"
        } else {
            title = paused ? "Detection paused" : "No live call detected"
        }
        menu.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))

        if case .live(let handle) = state {
            if let detail = handle.detail {
                let item = NSMenuItem(title: detail.truncated(60), action: nil, keyEquivalent: "")
                item.indentationLevel = 1
                menu.addItem(item)
            }
            let jump = NSMenuItem(title: "Jump to Call", action: #selector(jumpFromMenu), keyEquivalent: "j")
            jump.target = self
            menu.addItem(jump)
        }

        menu.addItem(.separator())

        let pauseItem = NSMenuItem(
            title: paused ? "Resume Detection" : "Pause Detection",
            action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let loginItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = LoginItem.isEnabled ? .on : .off
        menu.addItem(loginItem)

        let configItem = NSMenuItem(title: "Open Config File", action: #selector(openConfig), keyEquivalent: "")
        configItem.target = self
        menu.addItem(configItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit JumpCall", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        return menu
    }

    // MARK: - Menu actions

    @objc private func jumpFromMenu() {
        onJumpRequested?()
    }

    @objc private func togglePause() {
        paused.toggle()
        engine.setPaused(paused)
        update(state: paused ? .none : state)
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if LoginItem.isEnabled {
                try LoginItem.disable()
            } else {
                try LoginItem.enable()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Could not update Login Item"
            alert.informativeText = "\(error.localizedDescription)\n\nTip: run `jumpcall install` so JumpCall lives in ~/Applications, or use `jumpcall install --launchagent` as a fallback."
            alert.runModal()
        }
    }

    @objc private func openConfig() {
        _ = ConfigStore.load() // materializes the default file on first use
        NSWorkspace.shared.open(ConfigStore.configFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Icons

    private static func idleImage() -> NSImage? {
        let image = NSImage(systemSymbolName: "video", accessibilityDescription: "No live call")
        image?.isTemplate = true
        return image
    }

    private static func liveImage(style: String) -> NSImage? {
        guard style == "badge" else {
            let image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: "Live call")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemGreen]))
            image?.isTemplate = false
            return image
        }
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            if let symbol = NSImage(systemSymbolName: "video", accessibilityDescription: "Live call")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.labelColor])) {
                symbol.draw(in: rect.insetBy(dx: 0, dy: 2))
            }
            NSColor.systemGreen.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.minY, width: 6, height: 6)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

private extension String {
    func truncated(_ max: Int) -> String {
        count <= max ? self : String(prefix(max - 1)) + "…"
    }
}
