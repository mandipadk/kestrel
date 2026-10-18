import Foundation
import NetworkExtension

/// A device identity as carried by the setup QR code on the Kestrel page:
/// `kestrel1:` + base64url(JSON {n: name, s: secret, e: endpoint, k: exit key}).
struct DeviceKey: Codable, Equatable {
    let n: String
    let s: String
    let e: String
    let k: String

    var name: String { n }
    var endpoint: String { e }

    static func parse(_ text: String) -> DeviceKey? {
        if case .success(let key) = decode(text) { return key }
        return nil
    }

    /// Decodes a setup code, or says in plain words what is wrong with it.
    static func decode(_ text: String) -> Result<DeviceKey, SetupCodeError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("kestrel1:") else { return .failure(.notKestrel) }
        var b64 = String(trimmed.dropFirst("kestrel1:".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let fields = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure(.unreadable)
        }
        let isHex64 = { (v: Any?) -> Bool in
            guard let s = v as? String, s.count == 64 else { return false }
            return s.allSatisfy(\.isHexDigit)
        }
        guard let name = fields["n"] as? String, !name.isEmpty else { return .failure(.missing("device name")) }
        guard isHex64(fields["s"]) else { return .failure(.missing("device key")) }
        guard isHex64(fields["k"]) else { return .failure(.missing("exit key")) }
        guard let e = fields["e"] as? String, let port = e.split(separator: ":").last, Int(port) != nil else {
            return .failure(.missing("exit address"))
        }
        return .success(DeviceKey(n: name, s: fields["s"] as! String, e: e, k: fields["k"] as! String))
    }

    /// The geph5-client config for this device: no broker, straight to our exit.
    var clientConfig: String {
        let cfg: [String: Any] = [
            "exit_constraint": ["direct": "\(e)/\(k)"],
            "allow_direct": false,
            "broker": NSNull(),
            "broker_keys": NSNull(),
            "cache": NSNull(),
            "spoof_dns": false,
            "passthrough_china": false,
            "allow_lan": false,
            "kestrel_device": ["name": n, "secret": s],
        ]
        let data = try! JSONSerialization.data(withJSONObject: cfg)
        return String(data: data, encoding: .utf8)!
    }
}

enum SetupCodeError: Error {
    case notKestrel
    case unreadable
    case missing(String)

    var message: String {
        switch self {
        case .notKestrel:
            return "That isn't a Kestrel setup code."
        case .unreadable:
            return "That Kestrel code couldn't be read. On the Kestrel page, rotate this device's key and scan the new code."
        case .missing(let what):
            return "That Kestrel code has no valid \(what). On the Kestrel page, rotate this device's key and scan the new code."
        }
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
    @Published var error: String?

    private var manager: NETunnelProviderManager?
    private var observer: NSObjectProtocol?

    func load() async {
        let managers = (try? await NETunnelProviderManager.loadAllFromPreferences()) ?? []
        manager = managers.first
        if let proto = manager?.protocolConfiguration as? NETunnelProviderProtocol,
           let raw = proto.providerConfiguration?["key"] as? String {
            device = DeviceKey.parse(raw)
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
        // A start that ends in Off: ask iOS why, and say so.
        if status == .disconnected, attempting, previous != .disconnected, let conn {
            attempting = false
            conn.fetchLastDisconnectError { [weak self] err in
                guard let err = err as NSError? else { return }
                Task { @MainActor in self?.error = TunnelModel.explain(err) }
            }
        }
        connectedSince = status == .connected ? conn?.connectedDate : nil
        if status == .connected {
            Task { await checkAddress() }
        } else {
            publicIP = nil
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
            self.error = "iOS did not save the VPN: \(error.localizedDescription)"
        }
    }

    func toggle() async {
        guard let m = manager else { return }
        error = nil
        if status == .connected || status == .connecting || status == .reasserting {
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

    /// Turns the error iOS kept from the last attempt into something readable,
    /// keeping the code so a report can say exactly what happened.
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

    /// The engine's own view (state and recent log lines), from the running tunnel.
    func engineReport() async -> String {
        guard let session = manager?.connection as? NETunnelProviderSession, status == .connected else {
            return error ?? "Not connected. Last status: \(status.rawValue)."
        }
        return await withCheckedContinuation { cont in
            do {
                try session.sendProviderMessage(Data("report".utf8)) { data in
                    guard let data,
                          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        cont.resume(returning: "The tunnel didn't answer.")
                        return
                    }
                    let logs = (obj["logs"] as? [String] ?? []).joined(separator: "\n")
                    cont.resume(returning: "Engine: \(obj["state"] ?? "?")\n\n\(logs)")
                }
            } catch {
                cont.resume(returning: "Couldn't ask the tunnel: \(error.localizedDescription)")
            }
        }
    }

    func setOnDemand(_ on: Bool) async {
        guard let m = manager else { return }
        m.onDemandRules = on ? [NEOnDemandRuleConnect()] : []
        m.isOnDemandEnabled = on
        do {
            try await m.saveToPreferences()
            onDemand = on
        } catch {
            self.error = "Could not change that setting: \(error.localizedDescription)"
        }
    }

    func forget() async {
        guard let m = manager else { return }
        m.connection.stopVPNTunnel()
        try? await m.removeFromPreferences()
        manager = nil
        device = nil
        onDemand = false
        refreshStatus()
    }
}
