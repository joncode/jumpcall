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
    var onPrimaryClick: (() -> Void)?
    var onReturnRequested: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    private var lastMouseDown: Date?
    private var menuOnCallScreen = false
    private var menuCanReturn = false
    var hotkey: HotkeyManager?

    // macOS stores a status item's spot as "points from the right edge of the
    // screen" under this key — smaller is further right, and rightmost icons
    // are the last ones a crowded menu bar hides. There is no official
    // positioning API, but seeding the preference before creating the item
    // is honored, and a user's manual ⌘-drag simply overwrites it.
    private static let autosave = "JumpCall"
    private static let positionKey = "NSStatusItem Preferred Position \(autosave)"

    /// The rightmost third-party slot (macOS reserves the true far right
    /// for system items).
    private static let rightmost: Double = 8

    init(config: Config) {
        self.config = config
        if config.autoReposition {
            // Pinned: keep the icon at the rightmost slot, always.
            Self.seedPreferredPosition(force: Self.rightmost)
        } else {
            // Manual: seed a sensible default once; the user's ⌘-drag is final.
            Self.seedPreferredPosition(ifAbsent: Self.rightmost)
        }
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
        button.sendAction(on: [.leftMouseDown, .leftMouseUp, .rightMouseUp])
        applyState()
    }

    func update(state: CallState) {
        self.state = state
        applyState()
        reportDiagnostics()
    }

    /// Live config reload (Settings window): refresh icon style etc.
    /// Checking "keep far right" takes effect immediately.
    func apply(config: Config) {
        self.config = config
        applyState()
        enforcePinIfNeeded()
    }

    /// Pin mode: if anything (a drag, a login/wake re-layout, macOS itself)
    /// moved the icon out of the rightmost band, snap it back. Judged by the
    /// ACTUAL on-screen position — macOS rewrites the preference on its own
    /// (it parks unfittable items at the LEFT edge and stores that), so the
    /// stored value alone can't be trusted. Never fight a full menu bar:
    /// while the icon is overflow-hidden there is no room to reposition
    /// into (the one-shot rescue covers that case), and snap-backs are
    /// rate-limited so a recreate loop is impossible.
    private var lastPinFix = Date.distantPast

    private func enforcePinIfNeeded() {
        guard config.autoReposition else { return }
        let pref = UserDefaults.standard.double(forKey: Self.positionKey)
        let diag = currentDiagnostics()
        // Anything in the single-digit band IS rightmost (macOS normalizes
        // our 8 to 0 and back); larger values mean a drag or relocation.
        let prefDrifted = pref > 20
        let visiblyMisplaced = !diag.hidden && diag.hasWindow
            && diag.frame.origin.x < (NSScreen.main.map { $0.frame.width * 0.6 } ?? 1000)
        guard prefDrifted || visiblyMisplaced else { return }
        guard !diag.hidden else { return } // no room — repositioning is futile
        guard Date().timeIntervalSince(lastPinFix) > 300 else { return }
        lastPinFix = Date()
        repositionRight()
    }

    private func repositionRight() {
        NSStatusBar.system.removeStatusItem(statusItem)
        Self.seedPreferredPosition(force: Self.rightmost)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureItem()
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
        enforcePinIfNeeded()
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
        repositionRight()
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
            "automationDenied": AutomationStatus.shared.deniedTargets,
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
        guard let event = NSApp.currentEvent else { return }
        switch event.type {
        case .leftMouseDown:
            lastMouseDown = Date()
        case .leftMouseUp:
            let held = lastMouseDown.map { Date().timeIntervalSince($0) } ?? 0
            lastMouseDown = nil
            let isControlClick = event.modifierFlags.contains(.control)
            // Press-and-hold always means "show me the menu" — a universal
            // escape hatch that also covers call-screen detection misses.
            if isControlClick || held > 0.35 || !state.isLive {
                showMenu()
            } else {
                // Coordinator decides: away from the call → jump;
                // already on the call screen → menu (with Return item).
                onPrimaryClick?()
            }
        default:
            showMenu()
        }
    }

    /// Click landed while the user is already looking at the call.
    func showCallScreenMenu(canReturn: Bool) {
        menuOnCallScreen = true
        menuCanReturn = canReturn
        showMenu()
    }

    // The status item has no permanent menu (that would swallow left-clicks);
    // it is attached transiently, shown, then detached.
    private func showMenu() {
        statusItem.menu = buildMenu()
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
        menuOnCallScreen = false
        menuCanReturn = false
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        let title: String
        if case .live(let handle) = state {
            title = menuOnCallScreen
                ? "Live: \(handle.displayName) — you're on it"
                : "Live: \(handle.displayName)"
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
            let jump = NSMenuItem(title: "Jump to Call", action: #selector(jumpFromMenu), keyEquivalent: "")
            jump.target = self
            // Show the REAL global chord (it performs this exact action) —
            // never a made-up ⌘-shortcut that doesn't work outside the menu.
            if !menuOnCallScreen { applyHotkeyEquivalent(to: jump) }
            menu.addItem(jump)
            if menuOnCallScreen, menuCanReturn {
                let back = NSMenuItem(
                    title: "Return to Previous App",
                    action: #selector(returnFromMenu), keyEquivalent: "")
                back.target = self
                // From the call screen, the boomerang chord means "return".
                applyHotkeyEquivalent(to: back)
                menu.addItem(back)
            }
        }

        menu.addItem(.separator())

        if let hotkey {
            if hotkey.isActive {
                menu.addItem(NSMenuItem(
                    title: "Hotkey \(hotkey.spec.display): jump to call ⇄ back again",
                    action: nil, keyEquivalent: ""))
            } else {
                let item = NSMenuItem(
                    title: "Enable Hotkey \(hotkey.spec.display) — grant Accessibility…",
                    action: #selector(openAccessibilitySettings), keyEquivalent: "")
                item.target = self
                menu.addItem(item)
            }
        }

        let deniedBrowsers = AutomationStatus.shared.deniedTargets
        if !deniedBrowsers.isEmpty {
            let warn = NSMenuItem(
                title: "⚠ Meet tab scan blocked for \(deniedBrowsers.joined(separator: ", ")) — fix…",
                action: #selector(openAutomationSettings), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
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

        let githubItem = NSMenuItem(
            title: "JumpCall on GitHub…", action: #selector(openGitHub), keyEquivalent: "")
        githubItem.target = self
        menu.addItem(githubItem)

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

    /// Label a menu item with the user's actual global hotkey chord.
    private func applyHotkeyEquivalent(to item: NSMenuItem) {
        guard let hotkey, hotkey.isActive,
              let key = KeySpec.keyName(for: hotkey.spec.keyCode), key.count == 1 else { return }
        item.keyEquivalent = key
        var mask: NSEvent.ModifierFlags = []
        if hotkey.spec.flags.contains(.maskControl) { mask.insert(.control) }
        if hotkey.spec.flags.contains(.maskAlternate) { mask.insert(.option) }
        if hotkey.spec.flags.contains(.maskShift) { mask.insert(.shift) }
        if hotkey.spec.flags.contains(.maskCommand) { mask.insert(.command) }
        item.keyEquivalentModifierMask = mask
    }

    // MARK: - Menu actions

    @objc private func jumpFromMenu() {
        onJumpRequested?()
    }

    @objc private func returnFromMenu() {
        onReturnRequested?()
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

    @objc private func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openGitHub() {
        if let url = URL(string: "https://github.com/joncode/jumpcall") {
            NSWorkspace.shared.open(url)
        }
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
