import AppKit

let arguments = Array(CommandLine.arguments.dropFirst())

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
case "jump":
    CLI.jump()
case "version", "--version", "-V":
    print("jumpcall \(AppInfo.version)")
default:
    CLI.usage()
}

@MainActor
func runMenuBarApp() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
