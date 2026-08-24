import AppKit

@MainActor
final class StatusItemController: NSObject {
    private var statusItem: NSStatusItem
    weak var engine: DetectionEngine?
    private var config: Config
    private(set) var state: CallState = .none
    private var paused = false
    private var rescued = false
    private var diagnosticsTimer: Timer?

    var onJumpRequested: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var hotkey: HotkeyManager?

    // macOS stores a status item's spot as "points from the right edge of the
    // screen" under this key — smaller is further right, and rightmost icons
    // are the last ones a crowded menu bar hides. There is no official
    // positioning API, but seeding the preference before creating the item
    // is honored, and a user's manual ⌘-drag simply overwrites it.
    private static let autosave = "JumpCall"
    private static let positionKey = "NSStatusItem Preferred Position \(autosave)"

    init(config: Config) {
        self.config = config
        // Seed the rightmost third-party slot (macOS reserves the true far
        // right for system items). Seed-only: once the user ⌘-drags the icon,
        // their position is final — we never re-assert.
        Self.seedPreferredPosition(ifAbsent: 8)
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        configureItem()
        startDiagnostics()
    }

    private static func seedPreferredPosition(ifAbsent points: Double? = nil, force: Double? = nil) {
        let defaults = UserDefaults.standard
        if let force {
            defaults.set(force, forKey: positionKey)
        } else if let points, defaults.object(forKey: positionKey) == nil {
            defaults.set(points, forKey: positionKey)
        }
    }

    private func configureItem() {
        statusItem.autosaveName = Self.autosave
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusItemClicked)
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        applyState()
    }

    func update(state: CallState) {
        self.state = state
        applyState()
        reportDiagnostics()
    }

    /// Live config reload (Settings window): refresh icon style etc.
    func apply(config: Config) {
        self.config = config
        applyState()
    }

    private func applyState() {
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

    // MARK: - Visibility diagnostics & auto-rescue

    private struct IconDiagnostics {
        var hasWindow = false
        var frame: CGRect = .zero
        var windowVisible = false
        var occluded = true
        var onScreen = false
        var hidden: Bool { !hasWindow || !windowVisible || !onScreen || occluded }
    }

    private func startDiagnostics() {
        let timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.diagnosticsTick() }
        }
        diagnosticsTimer = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            self?.diagnosticsTick()
        }
    }

    private func diagnosticsTick() {
        let diag = currentDiagnostics()
        reportDiagnostics(diag)
        if diag.hidden, config.autoReposition, !rescued {
            rescued = true
            rescue()
        }
    }

    private func currentDiagnostics() -> IconDiagnostics {
        var diag = IconDiagnostics()
        guard let window = statusItem.button?.window else { return diag }
        diag.hasWindow = true
        diag.frame = window.frame
        diag.windowVisible = window.isVisible
        diag.occluded = !window.occlusionState.contains(.visible)
        diag.onScreen = NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        return diag
    }

    /// Re-create the status item at a further-right position: when the menu
    /// bar overflows, macOS then hides some other icon instead of ours.
    /// Once per launch, and only when actually hidden.
    private func rescue() {
        NSStatusBar.system.removeStatusItem(statusItem)
        Self.seedPreferredPosition(force: 8)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureItem()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            self.reportDiagnostics()
        }
    }

    /// Written for `jumpcall status` (a separate process) to read, so users
    /// get a straight answer to "is my icon even visible right now?".
    private func reportDiagnostics(_ diag: IconDiagnostics? = nil) {
        let d = diag ?? currentDiagnostics()
        let stateDescription: String
        if case .live(let handle) = state {
            stateDescription = "live: \(handle.displayName)"
        } else {
            stateDescription = paused ? "paused" : "none"
        }
        var hotkeyInfo: [String: Any] = ["enabled": false]
        if let hotkey {
            hotkeyInfo = ["enabled": true, "display": hotkey.spec.display, "active": hotkey.isActive]
        }
        let payload: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "pid": ProcessInfo.processInfo.processIdentifier,
            "state": stateDescription,
            "hotkey": hotkeyInfo,
            "icon": [
                "x": d.frame.origin.x,
                "y": d.frame.origin.y,
                "width": d.frame.width,
                "screenWidth": NSScreen.main?.frame.width ?? 0,
                "hasWindow": d.hasWindow,
                "windowVisible": d.windowVisible,
                "occluded": d.occluded,
                "onScreen": d.onScreen,
                "hidden": d.hidden,
                "rescued": rescued,
                "preferredPosition": UserDefaults.standard.double(forKey: Self.positionKey),
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: ConfigStore.runtimeFile, options: .atomic)
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

        if let hotkey {
            if hotkey.isActive {
                menu.addItem(NSMenuItem(
                    title: "Hotkey \(hotkey.spec.display): on (when a call is live)",
                    action: nil, keyEquivalent: ""))
            } else {
                let item = NSMenuItem(
                    title: "Enable Hotkey \(hotkey.spec.display) — grant Accessibility…",
                    action: #selector(openAccessibilitySettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        let pauseItem = NSMenuItem(
            title: paused ? "Resume Detection" : "Pause Detection",
            action: #selector(togglePause), keyEquivalent: "")
        pauseItem.target = self
        menu.addItem(pauseItem)

        let settingsItem = NSMenuItem(
            title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit JumpCall", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        menu.addItem(.separator())
        // No action → disabled → rendered grey. Small font to read as a hint.
        let hint = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        hint.attributedTitle = NSAttributedString(
            string: "JumpCall \(AppInfo.version)\nTo move this icon right in the menu bar:\nhold ⌘ (Command), then click-and-drag it.",
            attributes: [
                .font: NSFont.menuFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        menu.addItem(hint)

        return menu
    }

    // MARK: - Menu actions

    @objc private func jumpFromMenu() {
        onJumpRequested?()
    }

    @objc private func togglePause() {
        paused.toggle()
        engine?.setPaused(paused)
        update(state: paused ? .none : state)
    }

    @objc private func openAccessibilitySettings() {
        HotkeyManager.promptForAccessibility()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openSettings() {
        onOpenSettings?()
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
