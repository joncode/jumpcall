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
          jumpcall jump         one-shot: find the live call and focus it
          jumpcall version      print version

        detects: Zoom, Google Meet (Safari/Chrome/Brave tabs), Microsoft Teams,
        Webex, FaceTime. Config: ~/.config/jumpcall/config.json
        """)
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.1.0-dev"
    }
}
