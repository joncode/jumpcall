import AppKit

/// The single entry point the `jumpcall` executable calls.
public enum JumpCallMain {
    @MainActor
    public static func run(arguments: [String]) {
        switch arguments.first {
        case nil, "run":
            runMenuBarApp()
        case let arg? where arg.hasPrefix("-psn"): // legacy LaunchServices artifact
            runMenuBarApp()
        case "install":
            InstallCommand.install(args: Array(arguments.dropFirst()))
        case "uninstall":
            InstallCommand.uninstall(args: Array(arguments.dropFirst()))
        case "_register":
            InstallCommand.registerLoginItem()
        case "_unregister":
            InstallCommand.unregisterLoginItem()
        case "status":
            CLI.status(verbose: arguments.contains("--verbose") || arguments.contains("-v"))
        case "config":
            _ = ConfigStore.load() // materializes defaults on first use
            print(ConfigStore.configFile.path)
            NSWorkspace.shared.open(ConfigStore.configFile)
        case "jump":
            CLI.jump()
        case "version", "--version", "-V":
            print("jumpcall \(AppInfo.version)")
        default:
            CLI.usage()
        }
    }

    // NSApplication.delegate is a weak reference: without a strong ref of
    // our own, ARC is free to release the delegate right after the
    // assignment (optimization-dependent), leaving a menu-bar app that
    // launches and silently does nothing.
    @MainActor
    private static var delegate: AppDelegate?

    @MainActor
    private static func runMenuBarApp() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let appDelegate = AppDelegate()
        delegate = appDelegate
        app.delegate = appDelegate
        app.run()
    }
}
