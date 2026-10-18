import Foundation
import NetworkExtension
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import CoreWLAN
#endif

/// What the exit says about this device (asked through the tunnel).
struct ExitReport: Equatable {
    struct Shield: Equatable {
        var on: Bool
        var pausedUntil: Date?
        var lookups24h: Int
        var blocked24h: Int
        var blockedTotal: Int
        /// Blocked lookups per hour, oldest first, ending with this hour.
        var hourly: [Int]
        var top: [(domain: String, count: Int)]

        static func == (a: Shield, b: Shield) -> Bool {
            a.on == b.on && a.pausedUntil == b.pausedUntil && a.lookups24h == b.lookups24h
                && a.blocked24h == b.blocked24h && a.blockedTotal == b.blockedTotal && a.hourly == b.hourly
                && a.top.map(\.domain) == b.top.map(\.domain) && a.top.map(\.count) == b.top.map(\.count)
        }

        var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
        var active: Bool { on && !paused }
        /// Share of lookups that were trackers, 0...1.
        var share: Double { lookups24h == 0 ? 0 : Double(blocked24h) / Double(lookups24h) }
    }

    var device: String
    var stealth: Bool
    var exitCity: String
    var exitCountry: String
    var shield: Shield

    init(device: String, stealth: Bool, exitCity: String, exitCountry: String, shield: Shield) {
        self.device = device
        self.stealth = stealth
        self.exitCity = exitCity
        self.exitCountry = exitCountry
        self.shield = shield
    }

    init?(json: [String: Any]) {
        guard let device = json["device"] as? String else { return nil }
        let exit = json["exit"] as? [String: Any] ?? [:]
        let s = json["shield"] as? [String: Any] ?? [:]
        let int = { (v: Any?) in (v as? NSNumber)?.intValue ?? 0 }
        let paused = int(s["paused_until"])
        self.device = device
        stealth = json["stealth"] as? Bool ?? false
        exitCity = exit["city"] as? String ?? ""
        exitCountry = exit["country"] as? String ?? ""
        shield = Shield(
            on: s["enabled"] as? Bool ?? true,
            pausedUntil: paused > 0 ? Date(timeIntervalSince1970: TimeInterval(paused)) : nil,
            lookups24h: int(s["lookups_24h"]),
            blocked24h: int(s["blocked_24h"]),
            blockedTotal: int(s["blocked_total"]),
            hourly: (s["hourly"] as? [Any] ?? []).map(int),
            top: (s["top"] as? [[Any]] ?? []).compactMap { pair in
                guard pair.count == 2, let d = pair[0] as? String else { return nil }
                return (d, int(pair[1]))
            }
        )
    }
}

@MainActor
final class TunnelModel: ObservableObject {
    @Published var loaded = false
    @Published var device: DeviceKey?
    @Published var status: NEVPNStatus = .invalid
    @Published var connectedSince: Date?
    @Published var publicIP: String?
    @Published var onDemand = false
    @Published var trustedNetworks: [String] = []
    @Published var report: ExitReport?
    @Published var error: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var reportTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var isOn: Bool { status == .connected }
    var isBusy: Bool { [.connecting, .disconnecting, .reasserting].contains(status) }

    func load() async {
        trustedNetworks = defaults.stringArray(forKey: "trustedNetworks") ?? []
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first
        if let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
           let raw = proto.providerConfiguration?["key"] as? String {
            device = DeviceKey.parse(raw)
            // Settings saved by an older build: bring the engine config up to
            // date (it now asks for the stealth link).
            if let key = device, proto.providerConfiguration?["config"] as? String != key.clientConfig {
                await install(key, raw: raw)
            }
        }
        onDemand = manager?.isOnDemandEnabled ?? false
        observe()
        refreshStatus()
        loaded = true
    }

    private func observe() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshStatus() }
        }
    }

    private var attempting = false

    private func refreshStatus() {
        let conn = manager?.connection
        let previous = status
        status = conn?.status ?? .invalid
        if status == .connected { attempting = false }
        // A start that ends in Off: ask the system why, and say so.
        if status == .disconnected, attempting, previous != .disconnected, let conn {
            attempting = false
            conn.fetchLastDisconnectError { [weak self] err in
                guard let err = err as NSError? else { return }
                Task { @MainActor in self?.error = TunnelModel.explain(err) }
            }
        }
        connectedSince = status == .connected ? conn?.connectedDate : nil
        if status == .connected {
            if previous != .connected {
                Task { await checkAddress() }
                startReports()
            }
        } else {
            publicIP = nil
            reportTask?.cancel()
            reportTask = nil
        }
    }

    /// Asks Cloudflare which address we appear from: the exit's, if all is well.
    func checkAddress() async {
        guard let url = URL(string: "https://1.1.1.1/cdn-cgi/trace") else { return }
        for _ in 0..<3 {
            if let (data, _) = try? await URLSession.shared.data(from: url),
               let text = String(data: data, encoding: .utf8),
               let line = text.split(separator: "\n").first(where: { $0.hasPrefix("ip=") }) {
                publicIP = String(line.dropFirst(3))
                return
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }

    // MARK: - The exit's report

    /// Keeps the exit's report fresh while connected.
    private func startReports() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            // the first session takes a moment to come up
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            while !Task.isCancelled {
                await self?.askExit("status")
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
        }
    }

    func refreshReport() async {
        guard isOn else { return }
        await askExit("status")
    }

    /// Pauses Shield on this device for an hour (a site that needs a blocked
    /// domain), or ends the pause.
    func setShieldPaused(_ paused: Bool) async {
        await askExit(paused ? "shield-pause" : "shield-resume")
    }

    private func askExit(_ request: String) async {
        guard let reply = await message("exit:\(request)") else { return }
        if let json = reply["exit"] as? [String: Any], let report = ExitReport(json: json) {
            self.report = report
        }
    }

    private func message(_ text: String) async -> [String: Any]? {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else { return nil }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data(text.utf8)) { data in
                    let obj = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                    cont.resume(returning: obj)
                }
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    /// The engine's own view (state and recent log lines), from the running tunnel.
    func engineReport() async -> String {
        guard isOn else {
            return error ?? "Not connected. Last status: \(status.rawValue)."
        }
        guard let obj = await message("report") else { return "The tunnel didn't answer." }
        let logs = (obj["logs"] as? [String] ?? []).joined(separator: "\n")
        return "Engine: \(obj["state"] ?? "?")\n\n\(logs)"
    }

    // MARK: - Setup and switching

    func install(_ key: DeviceKey, raw: String) async {
        let m = manager ?? NETunnelProviderManager()
        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "dev.mandip.kestrel.tunnel"
        proto.serverAddress = key.endpoint
        proto.providerConfiguration = ["config": key.clientConfig, "key": raw]
        proto.disconnectOnSleep = false
        m.protocolConfiguration = proto
        m.localizedDescription = "Kestrel"
        m.isEnabled = true
        do {
            try await m.saveToPreferences()
            try await m.loadFromPreferences()
            manager = m
            device = key
            error = nil
            observe()
            refreshStatus()
        } catch {
            self.error = "The system did not save the VPN: \(error.localizedDescription)"
        }
    }

    func toggle() async {
        guard let m = manager else { return }
        error = nil
        if isOn || isBusy {
            if m.isOnDemandEnabled { await setOnDemand(false) }
            m.connection.stopVPNTunnel()
            return
        }
        do {
            if !m.isEnabled {
                m.isEnabled = true
                try await m.saveToPreferences()
                try await m.loadFromPreferences()
            }
            attempting = true
            try m.connection.startVPNTunnel()
        } catch {
            attempting = false
            self.error = "Could not connect: \(error.localizedDescription)"
        }
    }

    /// Turns the error the system kept from the last attempt into something
    /// readable, keeping the code so a report can say exactly what happened.
    static func explain(_ err: NSError) -> String {
        var text = "Couldn't connect: \(err.localizedDescription)"
        if err.domain != "dev.mandip.kestrel" {
            text += " [\(err.domain) \(err.code)]"
        }
        if let under = err.userInfo[NSUnderlyingErrorKey] as? NSError {
            text += " — \(under.localizedDescription) [\(under.domain) \(under.code)]"
        }
        return text
    }

    // MARK: - Connect automatically, except on trusted Wi-Fi

    /// The rules the system follows when "Connect automatically" is on: stay
    /// off on trusted Wi-Fi, connect everywhere else.
    static func onDemandRules(trusted: [String]) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []
        if !trusted.isEmpty {
            let home = NEOnDemandRuleDisconnect()
            home.interfaceTypeMatch = .wiFi
            home.ssidMatch = trusted
            rules.append(home)
        }
        rules.append(NEOnDemandRuleConnect())
        return rules
    }

    func setOnDemand(_ on: Bool) async {
        guard let m = manager else { return }
        m.onDemandRules = on ? Self.onDemandRules(trusted: trustedNetworks) : []
        m.isOnDemandEnabled = on
        do {
            try await m.saveToPreferences()
            onDemand = on
        } catch {
            self.error = "Could not change that setting: \(error.localizedDescription)"
        }
    }

    func setTrusted(_ networks: [String]) async {
        var seen = Set<String>()
        trustedNetworks = networks
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        defaults.set(trustedNetworks, forKey: "trustedNetworks")
        if onDemand { await setOnDemand(true) }
    }

    /// The Wi-Fi network this device is on, when the system will say.
    func currentNetwork() async -> String? {
        #if os(iOS)
        return await withCheckedContinuation { cont in
            NEHotspotNetwork.fetchCurrent { cont.resume(returning: $0?.ssid) }
        }
        #elseif os(macOS)
        return CWWiFiClient.shared().interface()?.ssid()
        #endif
    }

    #if os(macOS)
    /// True while the old `kestrel` command still points this Mac's proxies
    /// at its local client. Both at once would send traffic through twice.
    var legacyProxyOn: Bool {
        guard let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] else { return false }
        let socks = settings["SOCKSEnable"] as? Int == 1 && settings["SOCKSPort"] as? Int == 9909
        let web = settings["HTTPSEnable"] as? Int == 1 && settings["HTTPSPort"] as? Int == 9910
        return socks || web
    }
    #endif

    func forget() async {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
        try? await m.removeFromPreferences()
        manager = nil
        device = nil
        report = nil
        onDemand = false
        refreshStatus()
    }
}
