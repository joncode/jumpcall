import AppKit
import SwiftUI

/// Hosts the SwiftUI settings UI in a plain AppKit window (the app has no
/// storyboard/xib — everything is code, no Xcode required).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called on every settings change with the full new config; the owner
    /// persists it and live-applies (rebuild engine/hotkey).
    var onConfigChange: ((Config) -> Void)?
    private var window: NSWindow?

    func show(config: Config) {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let root = SettingsView(config: config) { [weak self] cfg in
            self?.onConfigChange?(cfg)
        }
        let hosting = NSHostingController(rootView: root)
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.title = "JumpCall Settings"
        newWindow.styleMask = [.titled, .closable]
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}

// MARK: - Root view

struct SettingsView: View {
    @State private var cfg: Config
    @State private var loginEnabled = LoginItem.isEnabled
    @State private var recording = false
    @State private var keyMonitor: Any?
    @State private var showingAddSheet = false
    let onChange: (Config) -> Void

    static let builtinNames: [String: String] = [
        "zoom": "Zoom", "meet": "Google Meet", "teams": "Microsoft Teams",
        "webex": "Webex", "facetime": "FaceTime",
    ]

    init(config: Config, onChange: @escaping (Config) -> Void) {
        _cfg = State(initialValue: config)
        self.onChange = onChange
    }

    var body: some View {
        Form {
            hotkeySection
            platformsSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 520)
        .onChange(of: cfg) { _, newValue in onChange(newValue) }
        .sheet(isPresented: $showingAddSheet) {
            AddCallAppSheet(
                existingPrefixes: Set(cfg.micMatchers.flatMap(\.bundlePrefixes))
            ) { bundleID, name in
                addCustomApp(bundleID: bundleID, name: name)
            }
        }
    }

    // MARK: Hotkey

    private var hotkeySection: some View {
        Section("Hotkey") {
            Toggle("Enable global hotkey", isOn: $cfg.hotkeyEnabled)
            LabeledContent("Shortcut") {
                Button(recording ? "Press shortcut… (esc cancels)"
                                 : (KeySpec.parse(cfg.hotkey)?.display ?? cfg.hotkey)) {
                    recording ? stopRecording() : startRecording()
                }
                .disabled(!cfg.hotkeyEnabled)
            }
            Text("Fires only while a call is live — otherwise the keys pass through to whatever app you're using.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func startRecording() {
        recording = true
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handleRecordedKey(event)
            return nil // swallow while recording
        }
    }

    private func stopRecording() {
        recording = false
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private func handleRecordedKey(_ event: NSEvent) {
        if event.keyCode == 53 { // escape
            stopRecording()
            return
        }
        let flags = event.modifierFlags
        // A chord without a real modifier would make that key unusable.
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
            return
        }
        if let chord = KeySpec.chordString(
            keyCode: CGKeyCode(event.keyCode),
            control: flags.contains(.control),
            option: flags.contains(.option),
            shift: flags.contains(.shift),
            command: flags.contains(.command),
            fn: flags.contains(.function)
        ) {
            cfg.hotkey = chord
            stopRecording()
        }
    }

    // MARK: Platforms

    private var sortedPlatforms: [PlatformConfig] {
        cfg.platforms.sorted { $0.priority < $1.priority }
    }

    private var platformsSection: some View {
        Section {
            ForEach(sortedPlatforms, id: \.id) { platform in
                platformRow(platform)
            }
            Button("Add Call App…") { showingAddSheet = true }
        } header: {
            Text("Call Apps")
        } footer: {
            Text("Order is priority: when two calls are live at once, the higher one wins.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func platformRow(_ platform: PlatformConfig) -> some View {
        HStack {
            Toggle(isOn: enabledBinding(platform.id)) {
                Text(displayName(platform.id))
            }
            Spacer()
            Button { move(platform.id, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(sortedPlatforms.first?.id == platform.id)
            Button { move(platform.id, by: 1) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.borderless)
                .disabled(sortedPlatforms.last?.id == platform.id)
            if Self.builtinNames[platform.id] == nil {
                Button { removeCustomApp(platform.id) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
            }
        }
        if platform.id == "meet" {
            DisclosureGroup("Browsers to scan for Meet") {
                ForEach(["safari", "chrome", "brave", "edge", "arc"], id: \.self) { browserID in
                    Toggle(isOn: browserBinding(browserID)) {
                        Text(Browser.known[browserID]?.appName ?? browserID)
                    }
                }
            }
            .padding(.leading, 16)
        }
    }

    private func displayName(_ id: String) -> String {
        Self.builtinNames[id]
            ?? cfg.micMatchers.first(where: { $0.id == id })?.displayName
            ?? id
    }

    private func enabledBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { cfg.platforms.first(where: { $0.id == id })?.enabled ?? false },
            set: { newValue in
                if let i = cfg.platforms.firstIndex(where: { $0.id == id }) {
                    cfg.platforms[i].enabled = newValue
                }
            })
    }

    private func browserBinding(_ id: String) -> Binding<Bool> {
        Binding(
            get: { cfg.browsers.contains(id) },
            set: { newValue in
                if newValue {
                    if !cfg.browsers.contains(id) { cfg.browsers.append(id) }
                } else {
                    cfg.browsers.removeAll { $0 == id }
                }
            })
    }

    private func move(_ id: String, by offset: Int) {
        var ordered = sortedPlatforms
        guard let index = ordered.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard ordered.indices.contains(target) else { return }
        ordered.swapAt(index, target)
        for (i, platform) in ordered.enumerated() {
            if let j = cfg.platforms.firstIndex(where: { $0.id == platform.id }) {
                cfg.platforms[j].priority = i + 1
            }
        }
    }

    private func addCustomApp(bundleID: String, name: String) {
        var id = name.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
        if id.isEmpty { id = bundleID.lowercased() }
        while cfg.platforms.contains(where: { $0.id == id }) { id += "-2" }
        cfg.micMatchers.append(MicMatcherConfig(
            id: id, displayName: name,
            bundlePrefixes: [bundleID],
            activateBundleID: bundleID,
            requireAppRunningPrefix: nil))
        cfg.platforms.append(PlatformConfig(
            id: id, enabled: true,
            priority: (cfg.platforms.map(\.priority).max() ?? 0) + 1))
    }

    private func removeCustomApp(_ id: String) {
        cfg.platforms.removeAll { $0.id == id }
        cfg.micMatchers.removeAll { $0.id == id }
    }

    // MARK: General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch at login", isOn: $loginEnabled)
                .onChange(of: loginEnabled) { _, newValue in
                    do {
                        if newValue { try LoginItem.enable() } else { try LoginItem.disable() }
                    } catch {
                        loginEnabled = LoginItem.isEnabled
                    }
                }
            Picker("Live-call icon style", selection: $cfg.iconStyle) {
                Text("Green icon").tag("tint")
                Text("Green badge").tag("badge")
            }
            DisclosureGroup("Advanced") {
                Stepper(
                    "Check for calls every \(Int(cfg.pollSeconds))s",
                    value: $cfg.pollSeconds, in: 2...30, step: 1)
                Toggle("Auto-reposition icon if the menu bar hides it", isOn: $cfg.autoReposition)
                Button("Edit Config File…") {
                    NSWorkspace.shared.open(ConfigStore.configFile)
                }
            }
        }
    }
}

// MARK: - Add Call App sheet

private struct DetectedApp: Identifiable, Equatable {
    let id: String // bundle id
    let name: String
}

struct AddCallAppSheet: View {
    let existingPrefixes: Set<String>
    let onAdd: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detected: [DetectedApp] = []
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a Call App").font(.headline)
            Text("""
            Start a call (or anything that turns the microphone on) in the app \
            you want JumpCall to detect — it will appear below the moment it \
            uses the mic. Works for native apps; web calls are covered already.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            List(detected) { app in
                HStack {
                    if let icon = appIcon(bundleID: app.id) {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    }
                    Text(app.name)
                    Text(app.id).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Add") {
                        onAdd(app.id, app.name)
                        dismiss()
                    }
                }
            }
            .frame(minHeight: 140)
            .overlay {
                if detected.isEmpty {
                    Text("Listening for apps using the microphone…")
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Button("Choose App…") { chooseApp() }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onReceive(ticker) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func refresh() {
        let mine = InstallCommand.bundleID
        let apps = AudioInputProbe.processesUsingMicrophone()
            .filter { !$0.bundleID.isEmpty && $0.bundleID != mine }
            .filter { candidate in !existingPrefixes.contains { candidate.bundleID.hasPrefix($0) } }
            .map { process in
                DetectedApp(
                    id: process.bundleID,
                    name: NSRunningApplication(processIdentifier: process.pid)?.localizedName
                        ?? ProcessProbe.processName(for: process.pid)
                        ?? process.bundleID.components(separatedBy: ".").last
                        ?? process.bundleID)
            }
        var seen = Set<String>()
        let unique = apps.filter { seen.insert($0.id).inserted }
        if unique != detected { detected = unique }
    }

    private func appIcon(bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return nil
        }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        onAdd(bundleID, name)
        dismiss()
    }
}
