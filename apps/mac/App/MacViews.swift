import AppKit
import CoreLocation
import SwiftUI

struct MacRootView: View {
    @EnvironmentObject var model: TunnelModel

    var body: some View {
        ZStack {
            Ink.bg.ignoresSafeArea()
            if !model.loaded {
                ProgressView().controlSize(.small).tint(Ink.muted)
            } else if model.device == nil {
                MacWelcomeView().transition(.opacity)
            } else {
                MacHomeView().transition(.opacity)
            }
        }
        .frame(width: 400)
        .frame(minHeight: 640)
        .animation(.easeOut(duration: 0.25), value: model.device?.name)
        .foregroundStyle(Ink.ink)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Welcome

struct MacWelcomeView: View {
    @EnvironmentObject var model: TunnelModel
    @State private var code = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark().padding(.top, 36)
            Spacer()
            Text("Your own way out,\nthrough Frankfurt.")
                .font(.geist(32, .semibold))
                .tracking(-1.0)
                .lineSpacing(2)
            Text("Kestrel only lets in devices you've added. On the Kestrel page, add this Mac and choose Open in Kestrel, or copy its setup code and paste it here.")
                .font(.geist(15))
                .foregroundStyle(Ink.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            Spacer()
            TextField("kestrel1:…", text: $code)
                .textFieldStyle(.plain)
                .font(.geistMono(13))
                .padding(.horizontal, 16)
                .frame(height: 48)
                .background(Ink.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Ink.line))
                .onSubmit { model.setUp(from: code) }
            if let err = model.error {
                Text(err).font(.geist(13)).foregroundStyle(Ink.danger).padding(.top, 12)
            }
            PrimaryButton(title: code.isEmpty ? "Paste setup code" : "Add this Mac",
                          systemImage: code.isEmpty ? "doc.on.clipboard" : "key", height: 48) {
                if code.isEmpty { code = NSPasteboard.general.string(forType: .string) ?? "" }
                model.setUp(from: code)
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }
}

// MARK: - Home

struct MacHomeView: View {
    @EnvironmentObject var model: TunnelModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                SettingsButton()
            }
            .padding(.top, 8)

            HStack(spacing: 12) {
                StatusDot(state: model.dotState)
                Text(model.statusWord)
                    .font(.geist(36, .semibold))
                    .tracking(-1.2)
                    .contentTransition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: model.statusWord)
            .padding(.top, 16)
            Text(model.statusLine)
                .font(.geist(15))
                .foregroundStyle(Ink.muted)
                .padding(.top, 8)

            VStack(spacing: 0) {
                FactRow(label: "Seen as", value: model.publicIP ?? (model.isOn ? "checking…" : "your own address"), mono: model.publicIP != nil, minHeight: 44)
                FactRow(label: "Exit", value: "Frankfurt", mono: false, minHeight: 44)
                FactRow(label: "Link", value: model.linkDescription, mono: false, minHeight: 44)
                FactRow(label: "This Mac", value: model.device?.name ?? "", mono: true, minHeight: 44)
            }
            .padding(.top, 28)

            if model.legacyProxyOn {
                LegacyNotice().padding(.top, 16)
            }

            ShieldPanel(shield: model.report?.shield, connected: model.isOn, topCount: 4) { paused in
                Task { await model.setShieldPaused(paused) }
            }
            .padding(.top, 20)
            .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
            .padding(.top, 8)

            Spacer(minLength: 24)

            if let err = model.error {
                Text(err).font(.geist(13)).foregroundStyle(Ink.danger).padding(.bottom, 12)
                    .textSelection(.enabled)
            }
            PrimaryButton(title: model.isOn || model.isBusy ? "Disconnect" : "Connect",
                          systemImage: model.isOn || model.isBusy ? "stop.fill" : "power",
                          inverted: model.isOn || model.isBusy, height: 48) {
                Task { await model.toggle() }
            }
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 32)
    }
}

/// The old command-line Kestrel set system proxies; with the app on too,
/// traffic would go through Frankfurt twice.
struct LegacyNotice: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Ink.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("The old Kestrel command is still on").font(.geist(14, .semibold))
                Text("Run kestrel off in Terminal once. This app replaces it.")
                    .font(.geist(13)).foregroundStyle(Ink.muted)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SettingsButton: View {
    var body: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
                NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 15))
                .foregroundStyle(Ink.muted)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Settings")
        .accessibilityLabel("Settings")
    }
}

// MARK: - Menu bar

struct MenuBarPanel: View {
    @EnvironmentObject var model: TunnelModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.device == nil {
                Text("Kestrel isn't set up on this Mac yet.")
                    .font(.geist(14))
                    .foregroundStyle(Ink.muted)
                    .padding(.bottom, 16)
            } else {
                HStack(spacing: 10) {
                    StatusDot(state: model.dotState)
                    Text(model.statusWord).font(.geist(20, .semibold)).tracking(-0.5)
                }
                Text(model.publicIP.map { "Seen as \($0)" } ?? model.statusLine)
                    .font(model.publicIP == nil ? .geist(13) : .geistMono(12))
                    .foregroundStyle(Ink.muted)
                    .padding(.top, 4)

                if model.isOn, let shield = model.report?.shield, shield.active {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Shield").font(.geist(13, .medium))
                        Spacer()
                        Text("\(shield.blocked24h.formatted()) blocked in 24 h").font(.geist(13)).foregroundStyle(Ink.muted)
                    }
                    .padding(.top, 16)
                    HourStrip(hourly: shield.hourly).frame(height: 20).padding(.top, 8)
                }

                PrimaryButton(title: model.isOn || model.isBusy ? "Disconnect" : "Connect",
                              systemImage: model.isOn || model.isBusy ? "stop.fill" : "power",
                              inverted: model.isOn || model.isBusy, height: 40) {
                    Task { await model.toggle() }
                }
                .padding(.vertical, 16)
            }
            Divider().overlay(Ink.line)
            MenuRow(title: "Open Kestrel") {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            MenuRow(title: "Quit Kestrel") { NSApp.terminate(nil) }
        }
        .padding(16)
        .frame(width: 280)
        .background(Ink.bg)
        .foregroundStyle(Ink.ink)
        .preferredColorScheme(.dark)
    }
}

struct MenuRow: View {
    let title: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.geist(14))
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .padding(.horizontal, 8)
                .background(hover ? Ink.raise : .clear, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -8)
        .onHover { hover = $0 }
    }
}

// MARK: - Settings

struct MacSettingsView: View {
    @EnvironmentObject var model: TunnelModel
    @State private var openAtLogin = LoginItem.enabled
    @State private var report = ""
    @State private var showReport = false
    @State private var confirmForget = false
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: Binding(get: { model.onDemand }, set: { v in Task { await model.setOnDemand(v) } })) {
                SettingText(title: "Connect automatically", detail: "Kestrel comes on by itself on any network, except Wi-Fi you trust.")
            }
            .toggleStyle(.switch)
            .tint(Ink.accent)
            .disabled(model.device == nil)
            .padding(.vertical, 12)

            MacTrustedNetworks().padding(.bottom, 12)

            Divider().overlay(Ink.line)
            Toggle(isOn: Binding(get: { openAtLogin }, set: { on in
                do {
                    try LoginItem.set(on)
                    loginError = nil
                } catch {
                    loginError = error.localizedDescription
                }
                openAtLogin = LoginItem.enabled
            })) {
                SettingText(title: "Open at login", detail: loginError ?? "Keep Kestrel in the menu bar from the moment you sign in.")
            }
            .toggleStyle(.switch)
            .tint(Ink.accent)
            .padding(.vertical, 12)

            Divider().overlay(Ink.line)
            HStack {
                SettingText(title: "Connection details", detail: "The engine's state and recent log lines, to copy into a report.")
                Spacer()
                Button("Show") {
                    Task {
                        report = await model.engineReport()
                        showReport = true
                    }
                }
            }
            .padding(.vertical, 12)

            Divider().overlay(Ink.line)
            HStack {
                SettingText(title: "Remove the key from this Mac", detail: "To shut this Mac out completely, revoke it on the Kestrel page too.")
                Spacer()
                Button("Remove…", role: .destructive) { confirmForget = true }
                    .disabled(model.device == nil)
            }
            .padding(.vertical, 12)
        }
        .padding(24)
        .frame(width: 460)
        .background(Ink.bg)
        .foregroundStyle(Ink.ink)
        .sheet(isPresented: $showReport) { MacReportSheet(report: report) }
        .confirmationDialog("Remove the key?", isPresented: $confirmForget) {
            Button("Remove", role: .destructive) { Task { await model.forget() } }
        } message: {
            Text("You'll need a new setup code to connect again.")
        }
    }
}

struct SettingText: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.geist(14, .medium))
            Text(detail).font(.geist(13)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct MacTrustedNetworks: View {
    @EnvironmentObject var model: TunnelModel
    @State private var adding = false
    @State private var name = ""
    @StateObject private var location = LocationGate()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trusted Wi-Fi").font(.geist(12, .medium)).foregroundStyle(Ink.muted)
            ForEach(model.trustedNetworks, id: \.self) { network in
                HStack {
                    Image(systemName: "wifi").foregroundStyle(Ink.muted)
                    Text(network).font(.geist(14))
                    Spacer()
                    Button {
                        Task { await model.setTrusted(model.trustedNetworks.filter { $0 != network }) }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Ink.muted)
                    }
                    .buttonStyle(.plain)
                    .help("Stop trusting \(network)")
                }
                .frame(minHeight: 32)
            }
            if adding {
                HStack {
                    TextField("Network name", text: $name).textFieldStyle(.roundedBorder).font(.geist(14)).onSubmit(save)
                    Button("Add", action: save).disabled(name.isEmpty)
                    Button("Cancel") { adding = false }
                }
                .padding(.top, 8)
            } else {
                Button {
                    Task {
                        // macOS only names the Wi-Fi to apps allowed to use location
                        await location.ask()
                        name = await model.currentNetwork() ?? ""
                        adding = true
                    }
                } label: {
                    Label("Trust a Wi-Fi network", systemImage: "plus").font(.geist(14))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.trustedNetworks)
    }

    private func save() {
        let n = name
        adding = false
        name = ""
        Task { await model.setTrusted(model.trustedNetworks + [n]) }
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connection details").font(.geist(18, .semibold))
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(report, forType: .string)
                }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            ScrollView {
                Text(report)
                    .font(.geistMono(11))
                    .foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
        .background(Ink.bg)
    }
}
