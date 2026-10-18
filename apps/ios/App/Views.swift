import NetworkExtension
import SwiftUI
import UIKit

// MARK: - Welcome

struct WelcomeView: View {
    @EnvironmentObject var model: TunnelModel
    @State private var scanning = false
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.top, 8)
            Spacer()
            Text("Your own way out,\nthrough Frankfurt.")
                .font(.geist(34, .semibold))
                .tracking(-1.0)
                .lineSpacing(2)
            Text("Kestrel only lets in devices you've added. Open the Kestrel page on your Mac, add this iPhone, and scan the code it shows.")
                .font(.geist(16))
                .foregroundStyle(Ink.muted)
                .padding(.top, 16)
            Spacer()
            if let message = message ?? model.error {
                Text(message)
                    .font(.geist(14))
                    .foregroundStyle(Ink.danger)
                    .padding(.bottom, 16)
            }
            PrimaryButton(title: "Add this iPhone", systemImage: "qrcode.viewfinder") { scanning = true }
            Button {
                Task { await use(UIPasteboard.general.string ?? "") }
            } label: {
                Text("Paste a setup code instead")
                    .font(.geist(15, .medium))
                    .foregroundStyle(Ink.muted)
                    .frame(maxWidth: .infinity, minHeight: 48)
            }
            .padding(.top, 8)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .sheet(isPresented: $scanning) {
            ScannerSheet { code in
                scanning = false
                Task { await use(code) }
            }
        }
    }

    private func use(_ code: String) async {
        let key: DeviceKey
        switch DeviceKey.decode(code) {
        case .success(let k): key = k
        case .failure(let problem):
            message = problem.message
            return
        }
        message = nil
        await model.install(key, raw: code)
        if let err = model.error { message = err }
    }
}

// MARK: - Home

struct HomeView: View {
    @EnvironmentObject var model: TunnelModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Wordmark()
                Spacer()
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 17, weight: .regular))
                        .foregroundStyle(Ink.muted)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Settings")
            }
            .padding(.top, 8)

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        StatusDot(state: model.dotState)
                        Text(model.statusWord)
                            .font(.geist(40, .semibold))
                            .tracking(-1.4)
                            .contentTransition(.opacity)
                    }
                    .animation(.easeOut(duration: 0.2), value: model.statusWord)
                    Text(model.statusLine)
                        .font(.geist(16))
                        .foregroundStyle(Ink.muted)
                        .padding(.top, 8)

                    VStack(spacing: 0) {
                        FactRow(label: "Seen as", value: model.publicIP ?? (model.isOn ? "checking…" : "your own address"), mono: model.publicIP != nil)
                        FactRow(label: "Exit", value: "Frankfurt", mono: false)
                        FactRow(label: "Link", value: model.linkDescription, mono: false)
                    }
                    .padding(.top, 32)

                    ShieldPanel(shield: model.report?.shield, connected: model.isOn) { paused in
                        Task { await model.setShieldPaused(paused) }
                    }
                    .padding(.top, 24)
                    .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
                    .padding(.top, 8)
                }
                .padding(.top, 40)
                .padding(.bottom, 24)
            }
            .refreshable { await model.refreshReport() }

            if let err = model.error {
                Text(err).font(.geist(14)).foregroundStyle(Ink.danger).padding(.bottom, 16)
            }
            PrimaryButton(title: model.isOn || model.isBusy ? "Disconnect" : "Connect",
                          systemImage: model.isOn || model.isBusy ? "stop.fill" : "power",
                          inverted: model.isOn || model.isBusy) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await model.toggle() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .sheet(isPresented: $showSettings) { SettingsSheet().presentationDetents([.large]) }
    }
}

// MARK: - Settings

struct SettingsSheet: View {
    @EnvironmentObject var model: TunnelModel
    @Environment(\.dismiss) var dismiss
    @State private var confirmForget = false
    @State private var report = ""
    @State private var showReport = false
    @State private var newNetwork = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Settings").font(.geist(22, .semibold)).tracking(-0.6).padding(.bottom, 24)

                Toggle(isOn: Binding(get: { model.onDemand }, set: { v in Task { await model.setOnDemand(v) } })) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Connect automatically").font(.geist(16, .medium))
                        Text("Kestrel comes on by itself on any network, except Wi-Fi you trust.").font(.geist(14)).foregroundStyle(Ink.muted)
                    }
                }
                .tint(Ink.accent)
                .padding(.vertical, 12)

                TrustedNetworks()
                    .padding(.bottom, 8)

                Divider().overlay(Ink.line)
                SettingsRow(icon: "waveform.path.ecg", title: "Connection details") {
                    Task {
                        report = await model.engineReport()
                        showReport = true
                    }
                }
                Divider().overlay(Ink.line)
                HStack {
                    Image(systemName: "iphone")
                    Text("This device").font(.geist(16, .medium))
                    Spacer()
                    Text(model.device?.name ?? "").font(.geistMono(14)).foregroundStyle(Ink.muted)
                }
                .frame(minHeight: 52)
                Divider().overlay(Ink.line)
                Button(role: .destructive) { confirmForget = true } label: {
                    HStack {
                        Image(systemName: "key.slash")
                        Text("Remove the key from this iPhone").font(.geist(16, .medium))
                        Spacer()
                    }
                    .foregroundStyle(Ink.danger)
                    .frame(minHeight: 52)
                }
                Text("To shut this iPhone out completely, revoke it on the Kestrel page too.")
                    .font(.geist(14)).foregroundStyle(Ink.muted)
            }
            .padding(24)
        }
        .background(Ink.raise.ignoresSafeArea())
        .sheet(isPresented: $showReport) { ReportSheet(report: report) }
        .confirmationDialog("Remove the key?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.forget(); dismiss() } }
        } message: {
            Text("You'll need a new setup code to connect again.")
        }
    }
}

/// The Wi-Fi networks where Kestrel stays off when connecting automatically.
struct TrustedNetworks: View {
    @EnvironmentObject var model: TunnelModel
    @State private var adding = false
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Trusted Wi-Fi").font(.geist(13, .medium)).foregroundStyle(Ink.muted).padding(.top, 8)
            ForEach(model.trustedNetworks, id: \.self) { network in
                HStack {
                    Image(systemName: "wifi").foregroundStyle(Ink.muted)
                    Text(network).font(.geist(16))
                    Spacer()
                    Button {
                        Task { await model.setTrusted(model.trustedNetworks.filter { $0 != network }) }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(Ink.muted).frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Stop trusting \(network)")
                }
                .frame(minHeight: 48)
                .transition(.opacity)
            }
            if adding {
                HStack {
                    TextField("Network name", text: $name)
                        .font(.geist(16))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused)
                        .onSubmit(save)
                    Button("Add", action: save).font(.geist(15, .semibold)).foregroundStyle(Ink.accent)
                        .frame(minHeight: 44)
                }
                .frame(minHeight: 48)
            } else {
                Button {
                    Task {
                        name = await model.currentNetwork() ?? ""
                        adding = true
                        focused = true
                    }
                } label: {
                    HStack {
                        Image(systemName: "plus")
                        Text("Trust a Wi-Fi network").font(.geist(16, .medium))
                        Spacer()
                    }
                    .foregroundStyle(Ink.ink)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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

struct SettingsRow: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                Text(title).font(.geist(16, .medium))
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Ink.faint)
            }
            .foregroundStyle(Ink.ink)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ReportSheet: View {
    let report: String

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Connection details").font(.geist(22, .semibold)).tracking(-0.6)
                Spacer()
                Button {
                    UIPasteboard.general.string = report
                } label: {
                    Image(systemName: "doc.on.doc").frame(width: 44, height: 44)
                }
                .accessibilityLabel("Copy")
            }
            ScrollView {
                Text(report)
                    .font(.geistMono(12))
                    .foregroundStyle(Ink.muted)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .background(Ink.raise.ignoresSafeArea())
        .foregroundStyle(Ink.ink)
    }
}
