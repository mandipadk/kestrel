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
            if let message {
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

    private var on: Bool { model.status == .connected }
    private var busy: Bool { [.connecting, .disconnecting, .reasserting].contains(model.status) }

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

            Spacer()

            HStack(spacing: 12) {
                StatusDot(state: on ? .live : busy ? .busy : .off)
                Text(statusWord)
                    .font(.geist(40, .semibold))
                    .tracking(-1.4)
                    .contentTransition(.opacity)
            }
            .animation(.easeOut(duration: 0.2), value: statusWord)
            Text(statusLine)
                .font(.geist(16))
                .foregroundStyle(Ink.muted)
                .padding(.top, 8)

            VStack(spacing: 0) {
                FactRow(label: "Seen as", value: model.publicIP ?? (on ? "checking…" : "your own address"), mono: model.publicIP != nil)
                FactRow(label: "Exit", value: "Frankfurt · \(model.device?.endpoint ?? "")", mono: false)
                FactRow(label: "This device", value: model.device?.name ?? "", mono: true)
            }
            .padding(.top, 32)

            Spacer()

            if let err = model.error {
                Text(err).font(.geist(14)).foregroundStyle(Ink.danger).padding(.bottom, 16)
            }
            PrimaryButton(title: on || busy ? "Disconnect" : "Connect",
                          systemImage: on || busy ? "stop.fill" : "power",
                          inverted: on || busy) {
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task { await model.toggle() }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 16)
        .sheet(isPresented: $showSettings) { SettingsSheet().presentationDetents([.medium]) }
    }

    private var statusWord: String {
        switch model.status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Stopping"
        default: return "Off"
        }
    }

    private var statusLine: String {
        if let since = model.connectedSince, on {
            return "Private since \(since.formatted(date: .omitted, time: .shortened))."
        }
        return busy ? "Talking to Frankfurt…" : "Your traffic goes the usual way."
    }
}

struct SettingsSheet: View {
    @EnvironmentObject var model: TunnelModel
    @Environment(\.dismiss) var dismiss
    @State private var confirmForget = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Settings").font(.geist(22, .semibold)).tracking(-0.6).padding(.bottom, 24)
            Toggle(isOn: Binding(get: { model.onDemand }, set: { v in Task { await model.setOnDemand(v) } })) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stay connected").font(.geist(16, .medium))
                    Text("Reconnect on its own whenever the network changes.").font(.geist(14)).foregroundStyle(Ink.muted)
                }
            }
            .tint(Ink.accent)
            .padding(.vertical, 12)
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
            Spacer()
        }
        .padding(24)
        .background(Ink.raise.ignoresSafeArea())
        .confirmationDialog("Remove the key?", isPresented: $confirmForget, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { Task { await model.forget(); dismiss() } }
        } message: {
            Text("You'll need a new setup code to connect again.")
        }
    }
}

// MARK: - Pieces

struct Wordmark: View {
    var body: some View {
        HStack(spacing: 10) {
            KestrelMark().frame(width: 24, height: 24)
            Text("Kestrel").font(.geist(17, .semibold)).tracking(-0.3)
        }
    }
}

/// The wing mark from the Kestrel page.
struct KestrelMark: View {
    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 32
            ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7 * s), with: .color(Color(white: 0.12)))
            var wing = Path()
            wing.move(to: CGPoint(x: 6 * s, y: 19.5 * s))
            wing.addCurve(to: CGPoint(x: 17 * s, y: 11.6 * s), control1: CGPoint(x: 10.5 * s, y: 18.5 * s), control2: CGPoint(x: 14.2 * s, y: 15.9 * s))
            wing.addLine(to: CGPoint(x: 18.4 * s, y: 15.7 * s))
            wing.addLine(to: CGPoint(x: 26 * s, y: 10.5 * s))
            wing.addLine(to: CGPoint(x: 22.8 * s, y: 18.9 * s))
            wing.addCurve(to: CGPoint(x: 11.5 * s, y: 25 * s), control1: CGPoint(x: 19.2 * s, y: 20 * s), control2: CGPoint(x: 15.4 * s, y: 21.4 * s))
            wing.addLine(to: CGPoint(x: 11.3 * s, y: 20.9 * s))
            wing.closeSubpath()
            ctx.fill(wing, with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: 19.5 * s, y: 11.3 * s, width: 2.2 * s, height: 2.2 * s)), with: .color(Ink.accent))
        }
    }
}

enum DotState { case live, busy, off }

struct StatusDot: View {
    let state: DotState
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(state == .off ? Ink.faint : Ink.accent)
            .frame(width: 12, height: 12)
            .opacity(state == .busy ? (pulse ? 0.35 : 1) : 1)
            .overlay(
                Circle().stroke(Ink.accent.opacity(state == .live ? (pulse ? 0 : 0.5) : 0), lineWidth: 1)
                    .scaleEffect(pulse ? 2.4 : 1)
            )
            .onAppear { withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: state == .busy)) { pulse = true } }
            .id(state)
    }
}

struct FactRow: View {
    let label: String
    let value: String
    let mono: Bool

    var body: some View {
        HStack {
            Text(label).font(.geist(15)).foregroundStyle(Ink.muted)
            Spacer()
            Text(value)
                .font(mono ? .geistMono(14) : .geist(15))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
    }
}

struct PrimaryButton: View {
    let title: String
    let systemImage: String
    var inverted = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).font(.geist(17, .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: 56)
            .foregroundStyle(inverted ? Ink.ink : Color.black)
            .background(inverted ? Ink.raise : Ink.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(inverted ? Ink.line : .clear))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: inverted)
    }
}
