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
        /// Just blocked for this device, newest first.
        var recent: [Blocked] = []
        /// Domains this device let through, and those let through on every device.
        var allowed: [String] = []
        var allowedEverywhere: [String] = []

        static func == (a: Shield, b: Shield) -> Bool {
            a.on == b.on && a.pausedUntil == b.pausedUntil && a.lookups24h == b.lookups24h
                && a.blocked24h == b.blocked24h && a.blockedTotal == b.blockedTotal && a.hourly == b.hourly
                && a.top.map(\.domain) == b.top.map(\.domain) && a.top.map(\.count) == b.top.map(\.count)
                && a.recent == b.recent && a.allowed == b.allowed && a.allowedEverywhere == b.allowedEverywhere
        }

        var paused: Bool { (pausedUntil ?? .distantPast) > Date() }
        var active: Bool { on && !paused }
        /// Share of lookups that were trackers, 0...1.
        var share: Double { lookups24h == 0 ? 0 : Double(blocked24h) / Double(lookups24h) }
    }

    struct Blocked: Equatable, Hashable {
        var domain: String
        var count: Int
        var last: Date
    }

    var device: String
    var stealth: Bool
    /// The session keys came from X25519 and ML-KEM-768 together.
    var quantumSafe: Bool
    var exitCity: String
    var exitCountry: String
    var shield: Shield
    /// All of the owner's exits, as the exit tells it.
    var exits: [KestrelExit]
    /// How this device reached the exit: "direct" or "disguised" (the engine says).
    var link: String

    init(device: String, stealth: Bool, quantumSafe: Bool = true, exitCity: String, exitCountry: String,
         shield: Shield, exits: [KestrelExit] = [], link: String = "direct") {
        self.link = link
        self.device = device
        self.stealth = stealth
        self.quantumSafe = quantumSafe
        self.exitCity = exitCity
        self.exitCountry = exitCountry
        self.shield = shield
        self.exits = exits
    }

    init?(json: [String: Any]) {
        guard let device = json["device"] as? String else { return nil }
        let exit = json["exit"] as? [String: Any] ?? [:]
        let s = json["shield"] as? [String: Any] ?? [:]
        let int = { (v: Any?) in (v as? NSNumber)?.intValue ?? 0 }
        let paused = int(s["paused_until"])
        self.device = device
        stealth = json["stealth"] as? Bool ?? false
        quantumSafe = json["quantum_safe"] as? Bool ?? false
        exits = (json["exits"] as? [[String: Any]] ?? []).compactMap { e in
            guard let city = e["city"] as? String, let endpoint = e["endpoint"] as? String,
                  let key = e["pubkey"] as? String, key.count == 64, key.allSatisfy(\.isHexDigit) else { return nil }
            let disguise = (e["disguise"] as? String).flatMap { $0.hasPrefix("wss://") ? $0 : nil }
            return KestrelExit(c: city, e: endpoint, k: key, d: disguise)
        }
        link = json["link"] as? String ?? "direct"
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
            },
            recent: (s["recent"] as? [[String: Any]] ?? []).compactMap { r in
                guard let d = r["domain"] as? String else { return nil }
                return Blocked(domain: d, count: int(r["count"]), last: Date(timeIntervalSince1970: TimeInterval(int(r["last"]))))
            },
            allowed: s["allowed"] as? [String] ?? [],
            allowedEverywhere: s["allowed_everywhere"] as? [String] ?? []
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
    /// All of the owner's exits this device knows (from its setup code, or
    /// learned from an exit's report), and the one to stay on (nil: automatic).
    @Published var exits: [KestrelExit] = []
    @Published var exitChoice: String?
    /// nil: automatic (direct, disguised when direct doesn't answer); "disguised": always.
    @Published var link: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?
    private var reportTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    var isOn: Bool { status == .connected }
    var isBusy: Bool { [.connecting, .disconnecting, .reasserting].contains(status) }

    func load() async {
        trustedNetworks = defaults.stringArray(forKey: "trustedNetworks") ?? []
        exits = (defaults.data(forKey: "exits")).flatMap { try? JSONDecoder().decode([KestrelExit].self, from: $0) } ?? []
        exitChoice = defaults.string(forKey: "exitChoice")
        link = defaults.string(forKey: "link")
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first
        if let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
           let raw = proto.providerConfiguration?["key"] as? String {
            device = DeviceKey.parse(raw)
            if exits.isEmpty, let x = device?.x { exits = x }
            // Settings saved by an older build: bring the engine config up to
            // date (stealth link, packet size, the exit list).
            if let key = device, proto.providerConfiguration?["config"] as? String != config(for: key) {
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
            if status == .disconnected { Task { await applyConfigIfIdle() } }
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

    /// Lets a domain through Shield for this device, or for all of them.
    func allow(_ domain: String, everywhere: Bool = false) async {
        await askExit("\(everywhere ? "shield-allow-all" : "shield-allow").\(domain)")
    }

    /// Blocks a domain again (undoes either kind of allow).
    func unallow(_ domain: String) async {
        await askExit("shield-unallow.\(domain)")
    }

    private func askExit(_ request: String) async {
        guard let reply = await message("exit:\(request)") else { return }
        if let json = reply["exit"] as? [String: Any], let report = ExitReport(json: json) {
            self.report = report
            await learnExits(report.exits)
        }
    }

    // MARK: - Exits

    /// The engine config for this device with its exits and choice.
    func config(for key: DeviceKey) -> String {
        key.clientConfig(exits: exits, choice: exitChoice, link: link)
    }

    /// An exit told us the owner's exits (it came through the tunnel, so it is
    /// ours): keep the list. Saving a changed VPN configuration can drop a live
    /// connection, so the engine gets it once the tunnel is next off.
    private func learnExits(_ told: [KestrelExit]) async {
        guard !told.isEmpty, Set(told) != Set(exits), device != nil else { return }
        exits = told
        defaults.set(try? JSONEncoder().encode(told), forKey: "exits")
        if let choice = exitChoice, !told.contains(where: { $0.c == choice }) {
            exitChoice = nil
            defaults.removeObject(forKey: "exitChoice")
        }
        await applyConfigIfIdle()
    }

    /// Saves the engine config if it changed and the tunnel is off.
    private func applyConfigIfIdle() async {
        guard !isOn, !isBusy, let key = device,
              let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
              let raw = proto.providerConfiguration?["key"] as? String,
              proto.providerConfiguration?["config"] as? String != config(for: key)
        else { return }
        await install(key, raw: raw)
    }

    /// Stays on one exit (a city), or nil for automatic; reconnects to apply it.
    func setExitChoice(_ city: String?) async {
        guard city != exitChoice else { return }
        exitChoice = city
        defaults.set(city, forKey: "exitChoice")
        await reinstallAndReconnect()
    }

    /// Always disguised ("disguised") or automatic (nil); reconnects to apply it.
    func setLink(_ mode: String?) async {
        guard mode != link else { return }
        link = mode
        defaults.set(mode, forKey: "link")
        await reinstallAndReconnect()
    }

    /// Whether any exit has a disguised address (the setting means nothing otherwise).
    var canDisguise: Bool { exits.contains { $0.d != nil } }

    private func reinstallAndReconnect() async {
        guard let key = device,
              let raw = (manager?.protocolConfiguration as? NETunnelProviderProtocol)?.providerConfiguration?["key"] as? String
        else { return }
        let wasOn = isOn || isBusy
        await install(key, raw: raw)
        if wasOn, let m = manager {
            m.connection.stopVPNTunnel()
            for _ in 0..<40 where m.connection.status != .disconnected {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            await toggle()
        }
    }

    /// The exit in use, as the exit says, or the only one there is.
    var exitName: String {
        if let city = report?.exitCity, !city.isEmpty { return city }
        if let choice = exitChoice { return choice }
        return exits.count > 1 ? "Automatic" : "Frankfurt"
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
        if exits.isEmpty, let x = key.x { exits = x }
        proto.providerConfiguration = ["config": config(for: key), "key": raw]
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
        // a new exit list or choice waiting for the tunnel to be off
        await applyConfigIfIdle()
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

    enum SampleState: String { case welcome, off, connected }

    /// Fills the model with labelled sample data instead of the real VPN
    /// (screenshots and previews only; the app does this when launched with
    /// -KestrelSample <state>).
    func applySample(_ state: SampleState) {
        loaded = true
        device = state == .welcome ? nil : Sample.device
        trustedNetworks = ["Home 5G", "Studio"]
        onDemand = true
        if state == .connected {
            status = .connected
            connectedSince = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: Date())
            publicIP = "203.0.113.7"
            report = Sample.report
            exits = Sample.exits
        } else {
            status = .disconnected
        }
    }

    static var launchSample: SampleState? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-KestrelSample"), i + 1 < args.count else { return nil }
        return SampleState(rawValue: args[i + 1])
    }

    func forget() async {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
        try? await m.removeFromPreferences()
        manager = nil
        device = nil
        report = nil
        onDemand = false
        exits = []
        exitChoice = nil
        defaults.removeObject(forKey: "exits")
        defaults.removeObject(forKey: "exitChoice")
        refreshStatus()
    }
}
