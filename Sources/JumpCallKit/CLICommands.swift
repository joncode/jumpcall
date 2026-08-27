import AppKit
import Foundation

@MainActor
enum CLI {
    static func status(verbose: Bool) {
        let config = ConfigStore.load()
        let registry = MatcherRegistry(config: config)
        print("jumpcall \(AppInfo.version)")
        print("config: \(ConfigStore.configFile.path)")
        print("launch at login: \(LoginItem.isEnabled ? "enabled" : "disabled")")
        printIconStatus()
        print("")
        print("detection (note: browser permission prompts from the CLI attach to your terminal app):")
        for matcher in registry.orderedMatchers {
            if let handle = matcher.detect() {
                let detail = handle.detail.map { " (\($0))" } ?? ""
                print("  \(matcher.displayName): LIVE\(detail)")
            } else {
                print("  \(matcher.displayName): no call")
            }
        }
        if verbose {
            print("")
            print("audio process objects (CoreAudio):")
            let processes = AudioInputProbe.list()
            if processes.isEmpty {
                print("  none reported — CoreAudio process-object API returned nothing")
            }
            for p in processes {
                let name = p.bundleID.isEmpty
                    ? (ProcessProbe.processName(for: p.pid) ?? "?")
                    : p.bundleID
                let flags = [
                    p.isRunningInput ? "MIC" : nil,
                    p.isRunningOutput ? "out" : nil,
                ].compactMap { $0 }.joined(separator: ",")
                print("  pid \(p.pid)\t\(name)\t\(flags.isEmpty ? "-" : flags)")
            }
            print("")
            print("CptHost (Zoom meeting helper) running: \(ProcessProbe.isProcessRunning(named: "CptHost"))")
        }
    }

    private static func printIconStatus() {
        guard let data = try? Data(contentsOf: ConfigStore.runtimeFile),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stamp = json["updatedAt"] as? String,
              let updated = ISO8601DateFormatter().date(from: stamp),
              let icon = json["icon"] as? [String: Any] else {
            print("menu-bar icon: unknown (app not running, or older version)")
            return
        }
        guard Date().timeIntervalSince(updated) < 120 else {
            print("menu-bar icon: unknown (app not running? last report \(stamp))")
            return
        }
        if let hotkey = json["hotkey"] as? [String: Any] {
            if hotkey["enabled"] as? Bool != true {
                print("hotkey: disabled in config")
            } else if hotkey["active"] as? Bool == true {
                print("hotkey: \(hotkey["display"] as? String ?? "?") active (consumed only while a call is live)")
            } else {
                print("hotkey: \(hotkey["display"] as? String ?? "?") waiting for Accessibility permission (System Settings → Privacy & Security → Accessibility → JumpCall)")
            }
        }
        let hidden = icon["hidden"] as? Bool ?? false
        if let denied = json["automationDenied"] as? [String], !denied.isEmpty {
            print("⚠ Meet tab scan BLOCKED for: \(denied.joined(separator: ", ")) — the app's browser permission is stale/denied.")
            print("  Fix: System Settings → Privacy & Security → Automation → JumpCall, or:")
            print("  tccutil reset AppleEvents io.github.joncode.jumpcall  (then approve the fresh prompts)")
        }
        if hidden {
            print("menu-bar icon: HIDDEN (menu bar is full; macOS hides overflow icons — the hotkey still works)")
        } else {
            let x = icon["x"] as? Double ?? 0
            let screen = icon["screenWidth"] as? Double ?? 0
            print("menu-bar icon: visible (x=\(Int(x)) of \(Int(screen)))")
        }
    }

    static func jump() {
        let config = ConfigStore.load()
        let registry = MatcherRegistry(config: config)
        for matcher in registry.orderedMatchers {
            if let handle = matcher.detect() {
                if matcher.jump(handle) {
                    print("jumped to \(handle.displayName)")
                } else {
                    print("found \(handle.displayName) but could not focus it")
                    exit(1)
                }
                return
            }
        }
        print("no live call detected")
    }

    static func usage() {
        print("""
        jumpcall \(AppInfo.version) — jump to your live video call from the menu bar

        usage:
          jumpcall              run the menu-bar app (foreground)
          jumpcall install      install to ~/Applications, add CLI symlink,
                                enable launch-at-login, and start it
                --launchagent   use a classic LaunchAgent instead of a Login Item
                --from <path>   install from a specific JumpCall.app
          jumpcall uninstall    stop and remove everything
                --purge         also delete ~/.config/jumpcall
          jumpcall status       show config + what each platform detector sees
                --verbose, -v   also dump CoreAudio mic-usage per process
          jumpcall config       print the config path and open the file
          jumpcall jump         one-shot: find the live call and focus it
          jumpcall version      print version

        detects: Zoom, Google Meet (Safari/Chrome/Brave tabs), Microsoft Teams,
        Webex, FaceTime — plus any app you add in Settings.
        Settings: right-click the menu-bar icon → Settings…
        Config file (power users): ~/.config/jumpcall/config.json
        """)
    }
}

enum AppInfo {
    static var version: String {
        if let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
            return v
        }
        // Invoked through the CLI symlink, Bundle.main can't see the app
        // bundle — resolve the real executable path and read Info.plist.
        let exec = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .resolvingSymlinksInPath()
        let plist = exec.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Info.plist")
        if let data = try? Data(contentsOf: plist),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let v = dict["CFBundleShortVersionString"] as? String {
            return v
        }
        return "dev"
    }
}
