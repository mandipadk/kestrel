import AppKit
import CoreLocation
import SwiftUI

let kestrelPage = URL(string: "https://kestrel.mandip.dev")!

// MARK: - Menu bar panel

/// What the wing in the menu bar opens: a switch to connect, the facts that
/// matter while connected, Shield, and menu-style rows. Sized and styled like
/// Control Center's modules.
struct MenuBarPanel: View {
    @EnvironmentObject var model: TunnelModel
    @ObservedObject private var updates = Updates.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.device != nil && model.isOn {
                connected
            }
            if let err = model.error {
                Text(err)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            ExtensionNotice(compact: true)
            if model.legacyProxyOn {
                Notice(symbol: "exclamationmark.triangle", title: "The old Kestrel command is still on",
                       detail: "Run kestrel off in Terminal once. This app replaces it.")
            }
            if let version = updates.waiting {
                Notice(symbol: "arrow.down.circle", title: "Kestrel \(version) is ready",
                       detail: "Install it now. Kestrel reopens by itself and your tunnel reconnects.",
                       button: "Install Update…", action: { updates.check() })
            }

            PanelDivider()
            if model.device == nil {
                Button { SetupView.open(openWindow) } label: { RowLabel("Set Up This Mac…") }
                    .buttonStyle(PanelRowStyle())
            }
            Button { NSWorkspace.shared.open(kestrelPage) } label: { RowLabel("Open Kestrel Page") }
                .buttonStyle(PanelRowStyle())
            Button { updates.check() } label: { RowLabel("Check for Updates…") }
                .buttonStyle(PanelRowStyle())
                .disabled(!updates.canCheck)
            SettingsLink { RowLabel("Settings…", shortcut: "⌘,") }
                .buttonStyle(PanelRowStyle())
                .keyboardShortcut(",")
                .simultaneousGesture(TapGesture().onEnded { NSApp.activate() })
            PanelDivider()
            Button { NSApp.terminate(nil) } label: { RowLabel("Quit Kestrel", shortcut: "⌘Q") }
                .buttonStyle(PanelRowStyle())
                .keyboardShortcut("q")
        }
        .padding(.vertical, 6)
        .frame(width: 300)
        .animation(.easeOut(duration: 0.2), value: model.isOn)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Kestrel").font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle("Connected", isOn: Binding(
                    get: { model.isOn || model.isBusy },
                    set: { on in if on != (model.isOn || model.isBusy) { Task { await model.toggle() } } }
                ))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(model.device == nil)
                .help(model.isOn ? "Disconnect" : "Connect through Frankfurt")
            }
            HStack(spacing: 6) {
                Circle().fill(dotColor).frame(width: 7, height: 7)
                Text(summary).foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private var dotColor: Color {
        model.isOn ? Ink.accent : model.isBusy ? Ink.accent.opacity(0.5) : Color.secondary.opacity(0.5)
    }

    private var summary: String {
        if model.device == nil { return "Not set up on this Mac yet" }
        if model.isOn { return "Connected through Frankfurt" }
        if model.isBusy { return "\(model.statusWord)…" }
        return "Off. Traffic goes the usual way"
    }

    @ViewBuilder private var connected: some View {
        VStack(spacing: 4) {
            KeyValue("Seen as", model.publicIP ?? "checking…", mono: model.publicIP != nil)
            KeyValue("Link", model.linkDescription)
            if let since = model.connectedSince {
                KeyValue("Connected", "since \(since.formatted(date: .omitted, time: .shortened))")
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)

        if let shield = model.report?.shield, shield.on {
            PanelDivider()
            HStack(alignment: .firstTextBaseline) {
                Text("Shield").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Text(shield.paused
                     ? "Paused until \((shield.pausedUntil ?? Date()).formatted(date: .omitted, time: .shortened))"
                     : "\(shield.blocked24h.formatted()) blocked in 24 h")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            HourStrip(hourly: shield.hourly, dim: shield.paused)
                .frame(height: 18)
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 4)
            Button { Task { await model.setShieldPaused(!shield.paused) } } label: {
                RowLabel(shield.paused ? "Resume Shield" : "Pause Shield for 1 Hour")
            }
            .buttonStyle(PanelRowStyle())
        }
    }
}

struct KeyValue: View {
    let key: String
    let value: String
    var mono = false

    init(_ key: String, _ value: String, mono: Bool = false) {
        self.key = key
        self.value = value
        self.mono = mono
    }

    var body: some View {
        HStack {
            Text(key).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .system(size: 12, design: .monospaced) : .system(size: 13))
                .textSelection(.enabled)
        }
        .font(.system(size: 13))
    }
}

struct PanelDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }
}

struct RowLabel: View {
    let title: String
    var shortcut: String?

    init(_ title: String, shortcut: String? = nil) {
        self.title = title
        self.shortcut = shortcut
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let shortcut { Text(shortcut).foregroundStyle(.tertiary) }
        }
        .font(.system(size: 13))
    }
}

/// A row that highlights under the pointer, like the rows in Control Center.
struct PanelRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PanelRow(configuration: configuration)
    }

    private struct PanelRow: View {
        let configuration: Configuration
        @State private var hover = false
        @Environment(\.isEnabled) private var enabled

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .padding(.horizontal, 9)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hover ? 0.08 : 0))
                )
                .contentShape(Rectangle())
                .padding(.horizontal, 5)
                .opacity(enabled ? 1 : 0.4)
                .onHover { hover = $0 }
        }
    }
}

/// Something the owner has to do, shown inline.
struct Notice: View {
    let symbol: String
    let title: String
    let detail: String
    var button: String?
    var action: (() -> Void)?
    /// the panel insets notices from its edges; windows align them with their content
    var inset: CGFloat = 10

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(Ink.accent)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let button, let action {
                    Button(button, action: action).controlSize(.small).padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, inset)
        .padding(.bottom, inset == 0 ? 0 : 6)
    }
}

// MARK: - Setup window

/// Shown only until this Mac has a key, or when a kestrel1: link fails.
struct SetupView: View {
    static let windowID = "setup"

    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: windowID)
        NSApp.activate()
    }

    @EnvironmentObject var model: TunnelModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var code = ""

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            KestrelMark().frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 0) {
                Text("Add this Mac to Kestrel").font(.system(size: 13, weight: .semibold))
                Text("On the Kestrel page, add a Mac and choose Open in Kestrel. Or copy its setup code and paste it here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
                TextField("kestrel1:…", text: $code)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(add)
                    .padding(.top, 12)
                ExtensionNotice(compact: false).padding(.top, 10)
                if let err = model.error {
                    Text(err)
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 8)
                }
                HStack {
                    Button("Open Kestrel Page") { NSWorkspace.shared.open(kestrelPage) }
                    Spacer()
                    Button("Paste") { code = NSPasteboard.general.string(forType: .string) ?? code }
                    Button("Add This Mac", action: add)
                        .keyboardShortcut(.defaultAction)
                        .disabled(code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(.top, 16)
            }
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 460)
        .onChange(of: model.device?.name) { _, name in
            if name != nil { dismissWindow(id: Self.windowID) }
        }
    }

    private func add() {
        model.setUp(from: code)
    }
}

// MARK: - Settings

struct MacSettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            WiFiSettings()
                .tabItem { Label("Wi-Fi", systemImage: "wifi") }
            ThisMacSettings()
                .tabItem { Label("This Mac", systemImage: "laptopcomputer") }
        }
        .frame(width: 500)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: TunnelModel
    @ObservedObject private var updates = Updates.shared
    @State private var openAtLogin = LoginItem.enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(get: { model.onDemand }, set: { v in Task { await model.setOnDemand(v) } })) {
                    Text("Connect automatically")
                    Text("On every network except Wi-Fi you trust.")
                }
                .disabled(model.device == nil)
                Toggle(isOn: Binding(get: { openAtLogin }, set: { on in
                    do {
                        try LoginItem.set(on)
                        loginError = nil
                    } catch {
                        loginError = error.localizedDescription
                    }
                    openAtLogin = LoginItem.enabled
                })) {
                    Text("Open at login")
                    Text(loginError ?? "Keep Kestrel in the menu bar from the moment you sign in.")
                }
            }
            Section {
                LabeledContent {
                    Text(shieldState).foregroundStyle(.secondary)
                } label: {
                    Text("Shield")
                    Text("Blocks ads, trackers and malware at the exit. Change it for each device on the Kestrel page.")
                }
            }
            Section {
                Toggle(isOn: Binding(get: { updates.checksAutomatically }, set: { updates.setChecksAutomatically($0) })) {
                    Text("Check for updates automatically")
                    Text("Once a day. Kestrel only installs an update signed with its release key.")
                }
                Toggle(isOn: Binding(get: { updates.installsAutomatically }, set: { updates.setInstallsAutomatically($0) })) {
                    Text("Download and install automatically")
                    Text("The update is applied the next time Kestrel quits or the Mac restarts.")
                }
                .disabled(!updates.checksAutomatically)
                LabeledContent {
                    Button("Check Now") { updates.check() }.disabled(!updates.canCheck)
                } label: {
                    Text("Kestrel \(updates.version)")
                    Text(updates.lastCheck.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 430)
    }

    private var shieldState: String {
        guard let shield = model.report?.shield else { return "Shown when connected" }
        if !shield.on { return "Off" }
        return shield.paused ? "Paused" : "On"
    }
}

struct WiFiSettings: View {
    @EnvironmentObject var model: TunnelModel
    @State private var selection: String?
    @State private var adding = false
    @State private var name = ""
    @StateObject private var location = LocationGate()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trusted Wi-Fi").font(.system(size: 13, weight: .semibold))
            VStack(spacing: 0) {
                List(model.trustedNetworks, id: \.self, selection: $selection) { network in
                    HStack(spacing: 6) {
                        Image(systemName: "wifi").foregroundStyle(.secondary)
                        Text(network)
                    }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 140)
                .overlay(alignment: .center) {
                    if model.trustedNetworks.isEmpty {
                        Text("No trusted networks").foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 0) {
                    Button { Task { await startAdding() } } label: {
                        Image(systemName: "plus").frame(width: 24, height: 20)
                    }
                    .help("Trust a Wi-Fi network")
                    Divider().frame(height: 14)
                    Button {
                        guard let s = selection else { return }
                        selection = nil
                        Task { await model.setTrusted(model.trustedNetworks.filter { $0 != s }) }
                    } label: {
                        Image(systemName: "minus").frame(width: 24, height: 20)
                    }
                    .disabled(selection == nil)
                    .help("Stop trusting the selected network")
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 2)
                .background(Color.primary.opacity(0.03))
                .overlay(alignment: .top) { Divider() }
            }
            .overlay(RoundedRectangle(cornerRadius: 1).stroke(Color.primary.opacity(0.12)))
            Text("With Connect automatically on, Kestrel stays off on these networks. Adding one asks for location access once, because macOS only tells apps the Wi-Fi name with it. Kestrel never reads your location.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(height: 270, alignment: .top)
        .disabled(model.device == nil)
        .sheet(isPresented: $adding) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Trust a Wi-Fi network").font(.system(size: 13, weight: .semibold))
                TextField("Network name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { adding = false }.keyboardShortcut(.cancelAction)
                    Button("Trust", action: save).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
                }
            }
            .padding(20)
            .frame(width: 320)
        }
    }

    private func startAdding() async {
        // macOS only names the Wi-Fi to apps allowed to use location
        await location.ask()
        name = await model.currentNetwork() ?? ""
        adding = true
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        adding = false
        name = ""
        guard !n.isEmpty else { return }
        Task { await model.setTrusted(model.trustedNetworks + [n]) }
    }
}

struct ThisMacSettings: View {
    @EnvironmentObject var model: TunnelModel
    @ObservedObject private var ext = TunnelExtension.shared
    @State private var report = ""
    @State private var showReport = false
    @State private var confirmRemove = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Device") {
                    Text(model.device?.name ?? "Not set up").font(.system(size: 12, design: .monospaced))
                }
                LabeledContent("Exit", value: model.report.map { "\($0.exitCity), \($0.exitCountry)" } ?? "Frankfurt")
                LabeledContent("Link", value: model.linkDescription)
                LabeledContent("Network extension", value: extensionState)
            }
            Section {
                LabeledContent {
                    Button("Show…") {
                        Task {
                            report = await model.engineReport()
                            showReport = true
                        }
                    }
                } label: {
                    Text("Connection details")
                    Text("The engine's state and recent log lines, to copy into a report.")
                }
                LabeledContent {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(model.device == nil)
                } label: {
                    Text("Remove the key from this Mac")
                    Text("To shut this Mac out completely, revoke it on the Kestrel page too.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 330)
        .sheet(isPresented: $showReport) { MacReportSheet(report: report) }
        .confirmationDialog("Remove the key from this Mac?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { Task { await model.forget() } }
        } message: {
            Text("You'll need a new setup code to connect again.")
        }
    }

    private var extensionState: String {
        switch ext.state {
        case .ready: return "Allowed"
        case .needsApproval: return "Waiting for you in System Settings"
        case .activating: return "Installing…"
        case .notInApplications: return "Move Kestrel to Applications"
        case .failed: return "Didn't install"
        case .unknown: return "Not checked yet"
        }
    }
}

/// Asks once for location access, which macOS requires before it will tell
/// an app the Wi-Fi network's name. Kestrel never reads a location.
@MainActor
final class LocationGate: NSObject, ObservableObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<Void, Never>?

    func ask() async {
        guard manager.authorizationStatus == .notDetermined else { return }
        manager.delegate = self
        await withCheckedContinuation { cont in
            waiting = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard manager.authorizationStatus != .notDetermined else { return }
            waiting?.resume()
            waiting = nil
        }
    }
}

struct MacReportSheet: View {
    let report: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connection details").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text(report)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(Rectangle().stroke(Color.primary.opacity(0.12)))
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560, height: 420)
    }
}
