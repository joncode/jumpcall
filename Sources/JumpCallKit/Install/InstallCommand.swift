import AppKit
import Foundation

@MainActor
public enum InstallCommand {
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
            // SMAppService binds to the right path. SMAppService has known
            // path/signing sensitivities (Error 78) — fall back to a classic
            // LaunchAgent automatically rather than leaving no login item.
            if runInstalled(["_register"]) != 0 {
                print("SMAppService registration failed — falling back to a LaunchAgent")
                installLaunchAgent()
            }
        }

        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [installedAppURL.path]
        try? open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else {
            fail("could not launch \(installedAppURL.path) — try opening it from Finder")
        }
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
               dest.contains("JumpCall.app"),
               !isHomebrewManaged(link: link) { // brew's link is brew's to remove
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
            exit(1)
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
            guard let bundle = appBundle(containing: URL(fileURLWithPath: args[i + 1]).absoluteURL)
            else {
                fail("""
                --from expects a JumpCall.app bundle (or a path inside one), \
                got: \(args[i + 1])
                """)
            }
            return bundle
        }
        // Homebrew symlinks /opt/homebrew/bin/jumpcall into the Cellar's
        // JumpCall.app, so Bundle.main reports /opt/homebrew/bin — resolve
        // the real executable and walk up to the enclosing bundle instead.
        let exec = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .absoluteURL
        return appBundle(containing: exec)
    }

    /// Resolves `url` — a bundle, a binary inside one, or a symlink to either —
    /// to the enclosing .app bundle, requiring the jumpcall binary inside it.
    public static func appBundle(containing url: URL) -> URL? {
        let fm = FileManager.default
        var candidate = url.resolvingSymlinksInPath()
        while candidate.path != "/" {
            if candidate.pathExtension == "app" {
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: candidate.path, isDirectory: &isDir),
                      isDir.boolValue,
                      fm.fileExists(atPath: candidate.appending(path: "Contents/MacOS/jumpcall").path)
                else { return nil }
                return candidate
            }
            candidate.deleteLastPathComponent()
        }
        return nil
    }

    /// True if `link` is a symlink to a live binary inside Homebrew's Cellar.
    /// Brew owns that link: replacing or removing it makes the next
    /// `brew upgrade`/`brew link` refuse with "possible conflicting files".
    public static func isHomebrewManaged(link: URL) -> Bool {
        let fm = FileManager.default
        guard let dest = try? fm.destinationOfSymbolicLink(atPath: link.path) else { return false }
        let target = URL(fileURLWithPath: dest, relativeTo: link.deletingLastPathComponent())
            .standardizedFileURL
        return target.path.contains("/Cellar/jumpcall/") && fm.fileExists(atPath: target.path)
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
        // Only ever replace a symlink. A regular file at this path is not
        // ours to delete (attributesOfItem does not traverse symlinks).
        if let attrs = try? fm.attributesOfItem(atPath: link.path) {
            guard attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
                print("note: \(link.path) exists and is not a symlink — leaving it alone")
                return
            }
            if isHomebrewManaged(link: link) {
                // The Cellar CLI is the same version; brew keeps it current.
                print("cli: \(link.path) (Homebrew-managed)")
                return
            }
            try? fm.removeItem(at: link)
        }
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

    @discardableResult
    private static func runInstalled(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = installedBinURL
        proc.arguments = args
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            print("could not run \(installedBinURL.path): \(error.localizedDescription)")
            return 1
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
        if launchctl(["bootstrap", "gui/\(getuid())", launchAgentURL.path]) != 0 {
            print("warning: launchctl bootstrap failed — the agent will load at next login")
        }
        print("launch agent installed: \(launchAgentURL.path)")
    }

    private static func removeLaunchAgent() {
        guard FileManager.default.fileExists(atPath: launchAgentURL.path) else { return }
        launchctl(["bootout", "gui/\(getuid())/\(bundleID)"])
        try? FileManager.default.removeItem(at: launchAgentURL)
        print("removed \(launchAgentURL.path)")
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = args
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return 1
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("jumpcall: \(message)\n".utf8))
        exit(1)
    }
}
