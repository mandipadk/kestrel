import CoreText
import SwiftUI

/// Kestrel's look on every screen: pure black, light ink, one rufous accent
/// (the bird's back), Geist for words and Geist Mono for addresses.
enum Ink {
    static let bg = Color.black
    static let raise = Color(white: 0.07)
    static let line = Color(white: 0.13)
    static let ink = Color(white: 0.96)
    static let muted = Color(white: 0.56)
    static let faint = Color(white: 0.36)
    static let accent = Color(red: 0.878, green: 0.482, blue: 0.271) // kestrel rufous
    static let danger = Color(red: 1.0, green: 0.42, blue: 0.37)
}

extension Font {
    static func geist(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist", size: size).weight(weight)
    }
    static func geistMono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .custom("Geist Mono", size: size).weight(weight)
    }
}

enum Fonts {
    /// Registers Geist from a bundle (the app's own fonts are registered by
    /// its Info.plist; tests and previews call this).
    static func register(from bundle: Bundle) {
        for name in ["Geist", "GeistMono"] {
            if let url = bundle.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }
}

// MARK: - Mark and status

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
    var tile = true

    var body: some View {
        Canvas { ctx, size in
            let s = size.width / 32
            if tile {
                ctx.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 7 * s), with: .color(Color(white: 0.12)))
            }
            ctx.fill(Self.wing(scale: s), with: .color(tile ? .white : Ink.ink))
            ctx.fill(Path(ellipseIn: CGRect(x: 19.5 * s, y: 11.3 * s, width: 2.2 * s, height: 2.2 * s)), with: .color(Ink.accent))
        }
    }

    static func wing(scale s: CGFloat) -> Path {
        var wing = Path()
        wing.move(to: CGPoint(x: 6 * s, y: 19.5 * s))
        wing.addCurve(to: CGPoint(x: 17 * s, y: 11.6 * s), control1: CGPoint(x: 10.5 * s, y: 18.5 * s), control2: CGPoint(x: 14.2 * s, y: 15.9 * s))
        wing.addLine(to: CGPoint(x: 18.4 * s, y: 15.7 * s))
        wing.addLine(to: CGPoint(x: 26 * s, y: 10.5 * s))
        wing.addLine(to: CGPoint(x: 22.8 * s, y: 18.9 * s))
        wing.addCurve(to: CGPoint(x: 11.5 * s, y: 25 * s), control1: CGPoint(x: 19.2 * s, y: 20 * s), control2: CGPoint(x: 15.4 * s, y: 21.4 * s))
        wing.addLine(to: CGPoint(x: 11.3 * s, y: 20.9 * s))
        wing.closeSubpath()
        return wing
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

extension TunnelModel {
    var dotState: DotState { isOn ? .live : isBusy ? .busy : .off }

    var statusWord: String {
        switch status {
        case .connected: return "Connected"
        case .connecting: return "Connecting"
        case .reasserting: return "Reconnecting"
        case .disconnecting: return "Stopping"
        default: return "Off"
        }
    }

    var statusLine: String {
        if let since = connectedSince, isOn {
            return "Private since \(since.formatted(date: .omitted, time: .shortened))."
        }
        return isBusy ? "Talking to Frankfurt…" : "Your traffic goes the usual way."
    }

    /// How the link to the exit looks on the wire.
    var linkDescription: String {
        guard isOn else { return "Hidden when connected" }
        guard let report else { return "checking…" }
        return report.stealth ? "Hidden" : "Plain"
    }
}

// MARK: - Rows and buttons

struct FactRow: View {
    let label: String
    let value: String
    let mono: Bool
    var minHeight: CGFloat = 52

    var body: some View {
        HStack {
            Text(label).font(.geist(15)).foregroundStyle(Ink.muted)
            Spacer()
            Text(value)
                .font(mono ? .geistMono(14) : .geist(15))
                .lineLimit(1)
                .truncationMode(.middle)
                .contentTransition(.opacity)
        }
        .frame(minHeight: minHeight)
        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
        .animation(.easeOut(duration: 0.2), value: value)
    }
}

struct PrimaryButton: View {
    let title: String
    let systemImage: String
    var inverted = false
    var height: CGFloat = 56
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage).font(.system(size: 16, weight: .semibold))
                Text(title).font(.geist(17, .semibold))
            }
            .frame(maxWidth: .infinity, minHeight: height)
            .foregroundStyle(inverted ? Ink.ink : Color.black)
            .background(inverted ? Ink.raise : Ink.ink, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(inverted ? Ink.line : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: inverted)
    }
}

// MARK: - Shield

/// What Shield did for this device in the last day: the count, an hourly
/// strip, and the domains it stopped most.
struct ShieldPanel: View {
    let shield: ExitReport.Shield?
    let connected: Bool
    var topCount = 3
    var onPause: ((Bool) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text("Shield").font(.geist(15, .semibold))
                } icon: {
                    Image(systemName: shieldIcon).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(shield?.active == true ? Ink.accent : Ink.faint)
                }
                Spacer()
                if let shield, let onPause, shield.on, connected {
                    Button(shield.paused ? "Resume" : "Pause for an hour") { onPause(!shield.paused) }
                        .buttonStyle(.plain)
                        .font(.geist(14, .medium))
                        .foregroundStyle(Ink.muted)
                        .frame(minHeight: 32)
                        .contentShape(Rectangle())
                }
            }
            Text(headline)
                .font(.geist(24, .semibold))
                .tracking(-0.6)
                .padding(.top, 12)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.3), value: shield?.blocked24h)
            Text(caption)
                .font(.geist(14))
                .foregroundStyle(Ink.muted)
                .padding(.top, 4)
            HourStrip(hourly: shield?.hourly ?? [], dim: shield?.active != true)
                .frame(height: 32)
                .padding(.top, 16)
            if let top = shield?.top.prefix(topCount), !top.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(top.enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.domain).font(.geistMono(13)).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text(item.count.formatted()).font(.geistMono(13)).foregroundStyle(Ink.muted)
                        }
                        .frame(minHeight: 36)
                        .overlay(alignment: .top) { Rectangle().fill(Ink.line).frame(height: 1) }
                    }
                }
                .padding(.top, 16)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.25), value: shield)
    }

    private var shieldIcon: String {
        guard let shield else { return "shield" }
        return shield.active ? "shield.lefthalf.filled" : "shield.slash"
    }

    private var headline: String {
        guard let shield else { return connected ? "Checking…" : "Off while disconnected" }
        if !shield.on { return "Off for this device" }
        if shield.paused, let until = shield.pausedUntil {
            return "Paused until \(until.formatted(date: .omitted, time: .shortened))"
        }
        return "\(shield.blocked24h.formatted()) blocked"
    }

    private var caption: String {
        guard let shield else { return "Ads, trackers and malware are stopped at the exit." }
        if !shield.on { return "Turn it on for this device on the Kestrel page." }
        if shield.lookups24h == 0 { return "Nothing looked up in the last 24 hours." }
        let pct = shield.share < 0.01 && shield.blocked24h > 0 ? "<1" : String(Int((shield.share * 100).rounded()))
        return "In the last 24 hours: \(pct)% of \(shield.lookups24h.formatted()) lookups were ads or trackers."
    }
}

/// Blocked lookups for each of the last 24 hours; the current hour in accent.
struct HourStrip: View {
    let hourly: [Int]
    var dim = false

    var body: some View {
        GeometryReader { geo in
            let values = hourly.isEmpty ? Array(repeating: 0, count: 24) : hourly
            let peak = max(values.max() ?? 0, 1)
            let gap: CGFloat = 3
            let width = (geo.size.width - gap * CGFloat(values.count - 1)) / CGFloat(values.count)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(Array(values.enumerated()), id: \.offset) { i, v in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(i == values.count - 1 && !dim ? Ink.accent : Ink.faint.opacity(dim ? 0.4 : 0.8))
                        .frame(width: max(width, 1), height: max(2, geo.size.height * CGFloat(v) / CGFloat(peak)))
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .accessibilityLabel("Blocked lookups per hour")
    }
}

// MARK: - Sample data (previews and screenshots)

enum Sample {
    #if os(iOS)
    static let deviceName = "iphone"
    #else
    static let deviceName = "macbook"
    #endif
    static let device = DeviceKey(n: deviceName, s: String(repeating: "0", count: 64), e: "203.0.113.7:443", k: String(repeating: "1", count: 64))

    /// Plausible numbers for a laptop's day, labelled as samples wherever shown.
    static let report = ExitReport(
        device: deviceName, stealth: true, exitCity: "Frankfurt", exitCountry: "DE",
        shield: .init(on: true, pausedUntil: nil, lookups24h: 9_412, blocked24h: 1_284, blockedTotal: 20_117,
                      hourly: [12, 8, 3, 0, 0, 0, 1, 4, 22, 61, 88, 93, 70, 102, 84, 77, 95, 120, 96, 74, 58, 66, 81, 70],
                      top: [("app-measurement.com", 212), ("browser-intake-datadoghq.com", 164), ("stats.g.doubleclick.net", 139),
                            ("graph.instagram.com", 97), ("sentry.io", 61)])
    )
}
