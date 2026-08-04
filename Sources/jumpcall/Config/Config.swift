import Foundation

struct PlatformConfig: Codable, Sendable {
    var id: String
    var enabled: Bool
    var priority: Int
}

/// A platform detected purely by "this app is using the microphone".
/// Users can add their own entries in config.json without touching code.
struct MicMatcherConfig: Codable, Sendable {
    var id: String
    var displayName: String
    /// Match if any mic-using process's bundle id starts with one of these.
    var bundlePrefixes: [String]
    /// App to activate on jump; defaults to the matched process's bundle id.
    var activateBundleID: String?
    /// Guard against system daemons owning the mic: only report a live call
    /// if an app with this bundle-id prefix is actually running.
    var requireAppRunningPrefix: String?
}

struct Config: Codable, Sendable {
    var pollSeconds: Double
    /// Probe browsers for Meet tabs only every Nth tick (they cost an
    /// osascript round-trip; everything else is sub-millisecond).
    var meetPollMultiplier: Int
    /// "tint" (green symbol when live) or "badge" (template symbol + green dot).
    var iconStyle: String
    /// If the icon gets hidden by menu-bar overflow, re-create it once at a
    /// more favorable (further right) position.
    var autoReposition: Bool
    /// Global hotkey chord, e.g. "ctrl+alt+cmd+m". Only consumed while a
    /// call is live — otherwise the key passes through untouched.
    var hotkey: String
    var hotkeyEnabled: Bool
    var browsers: [String]
    var platforms: [PlatformConfig]
    var micMatchers: [MicMatcherConfig]

    static let `default` = Config(
        pollSeconds: 5,
        meetPollMultiplier: 1,
        iconStyle: "tint",
        autoReposition: true,
        hotkey: "ctrl+alt+cmd+m",
        hotkeyEnabled: true,
        browsers: ["safari", "chrome", "brave"],
        platforms: [
            PlatformConfig(id: "zoom", enabled: true, priority: 1),
            PlatformConfig(id: "meet", enabled: true, priority: 2),
            PlatformConfig(id: "teams", enabled: true, priority: 3),
            PlatformConfig(id: "webex", enabled: true, priority: 4),
            PlatformConfig(id: "facetime", enabled: true, priority: 5),
        ],
        micMatchers: [
            MicMatcherConfig(
                id: "teams", displayName: "Microsoft Teams",
                bundlePrefixes: ["com.microsoft.teams"],
                activateBundleID: nil, requireAppRunningPrefix: nil),
            MicMatcherConfig(
                id: "webex", displayName: "Webex",
                bundlePrefixes: ["Cisco-Systems.Spark", "com.webex", "com.cisco.webex"],
                activateBundleID: nil, requireAppRunningPrefix: nil),
            MicMatcherConfig(
                id: "facetime", displayName: "FaceTime",
                bundlePrefixes: ["com.apple.FaceTime", "com.apple.avconferenced", "com.apple.TelephonyUtilities"],
                activateBundleID: "com.apple.FaceTime",
                requireAppRunningPrefix: "com.apple.FaceTime"),
        ]
    )

    init(
        pollSeconds: Double, meetPollMultiplier: Int, iconStyle: String, autoReposition: Bool,
        hotkey: String, hotkeyEnabled: Bool,
        browsers: [String], platforms: [PlatformConfig], micMatchers: [MicMatcherConfig]
    ) {
        self.pollSeconds = pollSeconds
        self.meetPollMultiplier = meetPollMultiplier
        self.iconStyle = iconStyle
        self.autoReposition = autoReposition
        self.hotkey = hotkey
        self.hotkeyEnabled = hotkeyEnabled
        self.browsers = browsers
        self.platforms = platforms
        self.micMatchers = micMatchers
    }

    // Tolerant decoding: any missing key falls back to the default, so old
    // config files keep working as new fields are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        pollSeconds = try c.decodeIfPresent(Double.self, forKey: .pollSeconds) ?? d.pollSeconds
        meetPollMultiplier = try c.decodeIfPresent(Int.self, forKey: .meetPollMultiplier) ?? d.meetPollMultiplier
        iconStyle = try c.decodeIfPresent(String.self, forKey: .iconStyle) ?? d.iconStyle
        autoReposition = try c.decodeIfPresent(Bool.self, forKey: .autoReposition) ?? d.autoReposition
        hotkey = try c.decodeIfPresent(String.self, forKey: .hotkey) ?? d.hotkey
        hotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .hotkeyEnabled) ?? d.hotkeyEnabled
        browsers = try c.decodeIfPresent([String].self, forKey: .browsers) ?? d.browsers
        platforms = try c.decodeIfPresent([PlatformConfig].self, forKey: .platforms) ?? d.platforms
        micMatchers = try c.decodeIfPresent([MicMatcherConfig].self, forKey: .micMatchers) ?? d.micMatchers
    }
}

enum ConfigStore {
    static var configDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".config/jumpcall", directoryHint: .isDirectory)
    }

    static var configFile: URL {
        configDir.appending(path: "config.json")
    }

    /// Live state the menu-bar app writes for the `status` CLI to read.
    static var runtimeFile: URL {
        configDir.appending(path: "runtime.json")
    }

    static func load() -> Config {
        let fm = FileManager.default
        if fm.fileExists(atPath: configFile.path) {
            if let data = try? Data(contentsOf: configFile),
               let cfg = try? JSONDecoder().decode(Config.self, from: data) {
                return cfg
            }
            // Malformed file: run on defaults but never overwrite the user's file.
            FileHandle.standardError.write(Data("jumpcall: could not parse \(configFile.path); using defaults\n".utf8))
            return .default
        }
        try? write(.default)
        return .default
    }

    static func write(_ cfg: Config) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(cfg).write(to: configFile, options: .atomic)
    }
}
