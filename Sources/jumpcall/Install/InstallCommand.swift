import AppKit
import Foundation

@MainActor
enum InstallCommand {
    static let bundleID = "io.github.joncode.jumpcall"

    static var installedAppURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Applications/JumpCall.app")
    }

    static var installedBinURL: URL {
        installedAppURL.appending(path: "Contents/MacOS/jumpcall")
    }

    static var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(bundleID).plist")
    }

    // MARK: - install

    static func install(args: [String]) {
        let fm = FileManager.default
        let useLaunchAgent = args.contains("--launchagent")

        guard let source = sourceBundle(args: args) else {
            fail("""
            could not locate a JumpCall.app bundle to install.
            Run `make install` from the repo, or `jumpcall install --from <path to JumpCall.app>`.
            """)
        }

        try? fm.createDirectory(
            at: installedAppURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        if source.standardizedFileURL.path != installedAppURL.standardizedFileURL.path {
            terminateRunningInstances()
            try? fm.removeItem(at: installedAppURL)
            do {
                try fm.copyItem(at: source, to: installedAppURL)
            } catch {
                fail("could not copy to \(installedAppURL.path): \(error.localizedDescription)")
            }
            print("installed \(installedAppURL.path)")
        }

        symlinkCLI()

        if useLaunchAgent {
            installLaunchAgent()
        } else {
            // Login-item registration must run from the *installed* bundle so
            // SMAppService binds to the right path.
            runInstalled(["_register"])
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [installedAppURL.path]
        try? open.run()
        open.waitUntilExit()
        print("JumpCall is running — look for the video icon in your menu bar.")
    }

    // MARK: - uninstall

    static func uninstall(args: [String]) {
        let fm = FileManager.default

        if fm.fileExists(atPath: installedBinURL.path) {
            runInstalled(["_unregister"])
        }
        removeLaunchAgent()
        terminateRunningInstances()

        for dir in symlinkDirs() {
            let link = dir.appending(path: "jumpcall")
            if let dest = try? fm.destinationOfSymbolicLink(atPath: link.path),
               dest.contains("JumpCall.app") {
                try? fm.removeItem(at: link)
                print("removed \(link.path)")
            }
        }

        if fm.fileExists(atPath: installedAppURL.path) {
            try? fm.removeItem(at: installedAppURL)
            print("removed \(installedAppURL.path)")
        }

        if args.contains("--purge") {
            try? fm.removeItem(at: ConfigStore.configDir)
            print("removed \(ConfigStore.configDir.path)")
        } else {
            print("config kept at \(ConfigStore.configDir.path) (use --purge to remove)")
        }
        print("note: any granted browser-automation permissions can be cleared with:")
        print("  tccutil reset AppleEvents \(bundleID)")
    }

    // MARK: - login item registration (run from the installed bundle)

    static func registerLoginItem() {
        do {
            try LoginItem.enable()
            print("launch at login: enabled")
        } catch {
            print("launch at login failed: \(error.localizedDescription)")
            print("fallback: jumpcall install --launchagent")
        }
    }

    static func unregisterLoginItem() {
        do {
            try LoginItem.disable()
            print("launch at login: disabled")
        } catch {
            print("launch at login unregister failed: \(error.localizedDescription)")
        }
    }

    // MARK: - helpers

    private static func sourceBundle(args: [String]) -> URL? {
        if let i = args.firstIndex(of: "--from"), args.indices.contains(i + 1) {
            return URL(fileURLWithPath: args[i + 1]).absoluteURL
        }
        let path = Bundle.main.bundlePath
        return path.hasSuffix(".app") ? URL(fileURLWithPath: path) : nil
    }

    private static func terminateRunningInstances() {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return }
        others.forEach { $0.terminate() }
        usleep(400_000)
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
            .forEach { $0.forceTerminate() }
    }

    private static func symlinkDirs() -> [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            URL(fileURLWithPath: "/usr/local/bin"),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin"),
        ]
    }

    private static func symlinkCLI() {
        let fm = FileManager.default
        var dir = symlinkDirs().first {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: $0.path, isDirectory: &isDir)
                && isDir.boolValue && fm.isWritableFile(atPath: $0.path)
        }
        if dir == nil {
            let local = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
            try? fm.createDirectory(at: local, withIntermediateDirectories: true)
            dir = local
        }
        guard let dir else { return }
        let link = dir.appending(path: "jumpcall")
        try? fm.removeItem(at: link)
        do {
            try fm.createSymbolicLink(atPath: link.path, withDestinationPath: installedBinURL.path)
            print("cli: \(link.path)")
            if link.path.contains(".local/bin") {
                print("note: make sure \(dir.path) is on your PATH")
            }
        } catch {
            print("could not create CLI symlink at \(link.path): \(error.localizedDescription)")
        }
    }

    private static func runInstalled(_ args: [String]) {
        let proc = Process()
        proc.executableURL = installedBinURL
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            print("could not run \(installedBinURL.path): \(error.localizedDescription)")
        }
    }

    // MARK: - LaunchAgent fallback

    private static func installLaunchAgent() {
        let plist: [String: Any] = [
            "Label": bundleID,
            "ProgramArguments": [installedBinURL.path],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(
                at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: launchAgentURL)
        } catch {
            fail("could not write \(launchAgentURL.path): \(error.localizedDescription)")
        }
        launchctl(["bootout", "gui/\(getuid())/\(bundleID)"]) // ignore failures
        launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path])
        print("launch agent installed: \(launchAgentURL.path)")
    }

    private static func removeLaunchAgent() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(bundleID)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        print("removed \(launchAgentURL.path)")
    }

    private static func launchctl(_ args: [String]) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("jumpcall: \(message)\n".utf8))
        exit(1)
    }
}
