import CoreGraphics
import Foundation
import JumpCallKit

// Minimal assert-based test runner. Deliberately framework-free: the Xcode
// Command Line Tools ship neither XCTest nor a working Swift Testing runner,
// and this project's promise is "no Xcode required". Run via `make test`.

var passed = 0
var failed = 0

@MainActor func expect(_ condition: Bool, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    if condition {
        passed += 1
    } else {
        failed += 1
        print("FAIL  \(label)  (\(file):\(line))")
    }
}

@MainActor func expectEqual<T: Equatable>(_ a: T, _ b: T, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
    if a == b {
        passed += 1
    } else {
        failed += 1
        print("FAIL  \(label): \(a) != \(b)  (\(file):\(line))")
    }
}

// MARK: - KeySpec

@MainActor func keySpecTests() {
    let spec = KeySpec.parse("ctrl+alt+cmd+m")
    expect(spec != nil, "default chord parses")
    expectEqual(spec?.keyCode, 46, "M keycode") // kVK_ANSI_M
    expectEqual(spec?.flags, [.maskControl, .maskAlternate, .maskCommand], "default chord flags")
    expectEqual(spec?.display, "⌃⌥⌘M", "default chord display")

    expectEqual(
        KeySpec.parse("Control+Option+Command+M"), KeySpec.parse("ctrl+opt+cmd+m"),
        "modifier aliases and case-insensitivity")

    let f5 = KeySpec.parse("shift+f5")
    expectEqual(f5?.keyCode, 96, "f5 keycode")
    expectEqual(f5?.flags, [.maskShift], "shift+f5 flags")
    expectEqual(f5?.display, "⇧f5", "shift+f5 display")

    expect(KeySpec.parse("ctrl+alt") == nil, "modifiers without key invalid")
    expect(KeySpec.parse("") == nil, "empty string invalid")
    expect(KeySpec.parse("ctrl+banana") == nil, "unknown key invalid")
    expect(KeySpec.parse("ctrl+m+j") == nil, "two keys invalid")

    let bare = KeySpec.parse("f13")
    expectEqual(bare?.keyCode, 105, "bare f13 keycode")
    expectEqual(bare?.flags, [], "bare key has no modifiers")

    expectEqual(KeySpec.default, KeySpec.parse("ctrl+alt+cmd+m"), "default constant")
}

// MARK: - Meet URL matching

@MainActor func meetURLTests() {
    let accepted = [
        "https://meet.google.com/abc-defg-hij",
        "https://meet.google.com/abc-defg-hij?authuser=1",
        "https://meet.google.com/abc-defg-hij#config",
        "https://meet.google.com/abc-defg-hij/",
        "https://meet.google.com/lookup/abc123",
        "https://meet.google.com/lookup/Abc-123?hs=180",
    ]
    for url in accepted {
        expect(MeetMatcher.isMeetingURL(url), "accepts \(url)")
    }
    let rejected = [
        "https://meet.google.com/",
        "https://meet.google.com/landing",
        "https://meet.google.com/new",
        "https://meet.google.com",
        "https://evil.example.com/meet.google.com/abc-defg-hij",
        "https://notmeet.google.com/abc-defg-hij",
        "http://meet.google.com/abc-defg-hij", // https only
        "https://meet.google.com/ab-cdef-ghi", // 2-4-3
        "https://meet.google.com/ABC-DEFG-HIJ", // uppercase
        "https://meet.google.com/abc-defg", // missing part
    ]
    for url in rejected {
        expect(!MeetMatcher.isMeetingURL(url), "rejects \(url)")
    }

    for id in ["safari", "chrome", "brave", "edge", "arc"] {
        expect(Browser.known[id] != nil, "browser registry has \(id)")
    }
    expectEqual(Browser.known["safari"]?.isChromium, false, "safari not chromium")
    expectEqual(Browser.known["chrome"]?.isChromium, true, "chrome is chromium")
}

// MARK: - Config

@MainActor func configTests() {
    do {
        let empty = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        expectEqual(empty.pollSeconds, Config.default.pollSeconds, "empty json: default pollSeconds")
        expectEqual(empty.hotkey, Config.default.hotkey, "empty json: default hotkey")
        expectEqual(empty.browsers, Config.default.browsers, "empty json: default browsers")
        expectEqual(empty.platforms.count, Config.default.platforms.count, "empty json: default platforms")

        let partial = try JSONDecoder().decode(
            Config.self, from: Data(#"{"pollSeconds": 2.5, "hotkeyEnabled": false}"#.utf8))
        expectEqual(partial.pollSeconds, 2.5, "partial override applies")
        expect(!partial.hotkeyEnabled, "partial override hotkeyEnabled")
        expectEqual(partial.iconStyle, Config.default.iconStyle, "partial keeps default iconStyle")
        expect(partial.autoReposition, "partial keeps default autoReposition")

        let data = try JSONEncoder().encode(Config.default)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        expectEqual(decoded.pollSeconds, Config.default.pollSeconds, "roundtrip pollSeconds")
        expectEqual(decoded.hotkey, Config.default.hotkey, "roundtrip hotkey")
        expectEqual(
            decoded.micMatchers.map(\.id), Config.default.micMatchers.map(\.id),
            "roundtrip micMatchers")

        let custom = try JSONDecoder().decode(Config.self, from: Data(#"""
            {"micMatchers": [{"id": "discord", "displayName": "Discord",
                              "bundlePrefixes": ["com.hnc.Discord"]}],
             "platforms": [{"id": "discord", "enabled": true, "priority": 1}]}
            """#.utf8))
        expectEqual(custom.micMatchers.first?.id, "discord", "custom mic matcher decodes")
        expect(custom.micMatchers.first?.activateBundleID == nil, "optional fields default nil")
        expectEqual(
            MatcherRegistry(config: custom).orderedMatchers.map(\.id), ["discord"],
            "registry builds custom mic matcher")
    } catch {
        failed += 1
        print("FAIL  config tests threw: \(error)")
    }

    var reordered = Config.default
    reordered.platforms = [
        PlatformConfig(id: "meet", enabled: true, priority: 1),
        PlatformConfig(id: "zoom", enabled: true, priority: 2),
        PlatformConfig(id: "teams", enabled: false, priority: 3),
    ]
    expectEqual(
        MatcherRegistry(config: reordered).orderedMatchers.map(\.id), ["meet", "zoom"],
        "registry respects priority and enabled")

    var unknown = Config.default
    unknown.platforms = [PlatformConfig(id: "mystery", enabled: true, priority: 1)]
    expect(
        MatcherRegistry(config: unknown).orderedMatchers.isEmpty,
        "unknown platform without mic matcher ignored")
}


// MARK: - AX window title heuristics

@MainActor func axTitleTests() {
    let calls = [
        "Meet – abc-defg-hij – Google Chrome",
        "abc-defg-hij – Meet",
        "(3) Standup | Microsoft Teams | Company – Google Chrome",
        "Webex Meeting – Google Chrome",
    ]
    for t in calls {
        expect(AXWindowProbe.titleLooksLikeCall(t), "call title: \(t)")
    }
    let notCalls = [
        "Meeting notes – Google Docs – Google Chrome",
        "[QA] Aoraki",
        "Zoom pricing – Google Chrome",
        "Inbox – you@example.com – Gmail",
    ]
    for t in notCalls {
        expect(!AXWindowProbe.titleLooksLikeCall(t), "non-call title: \(t)")
    }
}


@MainActor func axPickTests() {
    func w(_ title: String, _ area: Double) -> AXWindowInfo {
        AXWindowInfo(pid: 1, title: title, area: area, minimized: false)
    }
    let meet = w("Meet – abc-defg-hij", 1000)
    let teams = w("Standup | Microsoft Teams", 5000)
    let docs = w("Meeting notes – Google Docs", 9000)
    let aoraki = w("[QA] Aoraki", 8000)

    expectEqual(AXWindowProbe.pickCallWindow(from: [docs, teams, meet]), meet,
        "meeting-code match beats marker match regardless of size")
    expectEqual(AXWindowProbe.pickCallWindow(from: [docs, aoraki, teams]), teams,
        "marker match beats non-matches")
    expect(AXWindowProbe.pickCallWindow(from: [docs, aoraki]) == nil,
        "no call-looking window -> nil")
    let teamsBig = w("Retro | Microsoft Teams", 9000)
    expectEqual(AXWindowProbe.pickCallWindow(from: [teams, teamsBig]), teamsBig,
        "equal strength: larger window wins")
    expect(AXWindowProbe.pickCallWindow(from: []) == nil, "empty -> nil")
}


@MainActor func chordStringTests() {
    expectEqual(
        KeySpec.chordString(keyCode: 46, control: true, option: true, shift: false, command: true),
        "ctrl+alt+cmd+m", "chord string round-trips the default")
    expectEqual(
        KeySpec.chordString(keyCode: 96, control: false, option: false, shift: true, command: true),
        "shift+cmd+f5", "chord string with shift+cmd")
    expect(KeySpec.chordString(keyCode: 9999, control: true, option: false, shift: false, command: false) == nil,
        "unknown keycode -> nil")
    // Everything chordString emits must parse back.
    if let chord = KeySpec.chordString(keyCode: 38, control: true, option: true, shift: true, command: true, fn: true) {
        expect(KeySpec.parse(chord) != nil, "emitted chord parses: \(chord)")
    } else {
        failed += 1; print("FAIL  chordString returned nil for full-modifier j")
    }
}


@MainActor func micPriorityTests() {
    let safari = Browser.known["safari"]!
    let chrome = Browser.known["chrome"]!
    let brave = Browser.known["brave"]!
    let ordered = MeetMatcher.orderByMicPriority(
        [safari, chrome, brave], micBundleIDs: ["com.google.Chrome.helper"])
    expectEqual(ordered.map(\.id), ["chrome", "safari", "brave"],
        "mic-holding browser scanned first")
    let unchanged = MeetMatcher.orderByMicPriority(
        [safari, chrome, brave], micBundleIDs: [])
    expectEqual(unchanged.map(\.id), ["safari", "chrome", "brave"],
        "no mic: config order preserved")
}

// MARK: - Run

keySpecTests()
meetURLTests()
configTests()
axTitleTests()
axPickTests()
chordStringTests()
micPriorityTests()

print("\(passed) passed, \(failed) failed")
exit(failed == 0 ? 0 : 1)
