import ApplicationServices
import CoreGraphics
import Foundation

/// A parsed hotkey chord, e.g. "ctrl+alt+cmd+m".
struct KeySpec: Sendable, Equatable {
    let keyCode: CGKeyCode
    let flags: CGEventFlags
    let display: String

    static let `default` = KeySpec.parse("ctrl+alt+cmd+m")!

    /// Modifier names + one key name, joined by "+". Case-insensitive.
    static func parse(_ raw: String) -> KeySpec? {
        var flags: CGEventFlags = []
        var keyCode: CGKeyCode?
        var keyName = ""
        for part in raw.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "cmd", "command": flags.insert(.maskCommand)
            case "ctrl", "control": flags.insert(.maskControl)
            case "alt", "opt", "option": flags.insert(.maskAlternate)
            case "shift": flags.insert(.maskShift)
            case "fn": flags.insert(.maskSecondaryFn)
            default:
                guard keyCode == nil, let code = KeySpec.keyCodes[part] else { return nil }
                keyCode = code
                keyName = part
            }
        }
        guard let keyCode else { return nil }
        var display = ""
        if flags.contains(.maskControl) { display += "⌃" }
        if flags.contains(.maskAlternate) { display += "⌥" }
        if flags.contains(.maskShift) { display += "⇧" }
        if flags.contains(.maskCommand) { display += "⌘" }
        if flags.contains(.maskSecondaryFn) { display += "fn " }
        display += keyName.count == 1 ? keyName.uppercased() : keyName
        return KeySpec(keyCode: keyCode, flags: flags, display: display)
    }

    /// US-ANSI virtual key codes (kVK_ANSI_*).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "9": 25, "7": 26, "8": 28, "0": 29,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "-": 27, "=": 24, "[": 33, "]": 30, ";": 41, "'": 39, ",": 43, ".": 47, "/": 44, "\\": 42, "`": 50,
        "space": 49, "tab": 48, "return": 36, "escape": 53,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111, "f13": 105, "f14": 107, "f15": 113,
        "f16": 106, "f17": 64, "f18": 79, "f19": 80,
    ]
}

/// Global hotkey via CGEventTap — the only mechanism that allows conditional
/// pass-through: when no call is live, the chord is NOT consumed and behaves
/// exactly as if jumpcall didn't exist. Requires Accessibility permission;
/// degrades to inactive (with a menu hint) when not granted.
final class HotkeyManager: @unchecked Sendable {
    let spec: KeySpec
    private let isLive: @Sendable () -> Bool
    private let onTrigger: @Sendable () -> Void
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var retryTimer: Timer?

    private(set) var isActive = false

    init(spec: KeySpec, isLive: @escaping @Sendable () -> Bool, onTrigger: @escaping @Sendable () -> Void) {
        self.spec = spec
        self.isLive = isLive
        self.onTrigger = onTrigger
    }

    static var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    static func promptForAccessibility() {
        // Literal key for kAXTrustedCheckOptionPrompt: the C global is a
        // `var` and Swift 6 rejects cross-concurrency references to it.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Try to install the tap now; if Accessibility isn't granted yet, retry
    /// quietly every 10s so granting it mid-session just works — no restart.
    func startWhenPermitted(promptOnce: Bool) {
        if start() { return }
        if promptOnce { Self.promptForAccessibility() }
        let timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.start() {
                self.retryTimer?.invalidate()
                self.retryTimer = nil
            }
        }
        retryTimer = timer
    }

    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        isActive = true
        return true
    }

    func stop() {
        retryTimer?.invalidate()
        retryTimer = nil
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            eventTap = nil
        }
        isActive = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The OS disables taps it thinks are slow or during secure input;
        // re-enable and stay out of the way.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        guard CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == spec.keyCode else {
            return Unmanaged.passUnretained(event)
        }
        let relevant: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift, .maskSecondaryFn]
        guard event.flags.intersection(relevant) == spec.flags else {
            return Unmanaged.passUnretained(event)
        }
        // The pass-through contract: no live call → the key is not ours.
        guard isLive() else { return Unmanaged.passUnretained(event) }
        // Consume held-key autorepeats too, but only jump once.
        if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
            onTrigger()
        }
        return nil
    }
}
