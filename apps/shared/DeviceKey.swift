import Foundation

/// One of the owner's exits: city, endpoint, its public key, and its
/// disguised address (wss://, learnt from the exit's report) if it has one.
struct KestrelExit: Codable, Equatable, Hashable {
    let c: String
    let e: String
    let k: String
    var d: String? = nil

    var city: String { c }
}

/// A device identity as carried by the setup QR code on the Kestrel page:
/// `kestrel1:` + base64url(JSON {n: name, s: secret, e: endpoint, k: exit key,
/// x: [all exits], optional}).
struct DeviceKey: Codable, Equatable {
    let n: String
    let s: String
    let e: String
    let k: String
    var x: [KestrelExit]? = nil

    var name: String { n }
    var endpoint: String { e }

    /// Accepts the code itself or a `kestrel1:` link opened from the Kestrel page.
    static func parse(_ text: String) -> DeviceKey? {
        if case .success(let key) = decode(text) { return key }
        return nil
    }

    /// Decodes a setup code, or says in plain words what is wrong with it.
    static func decode(_ text: String) -> Result<DeviceKey, SetupCodeError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("kestrel1:") else { return .failure(.notKestrel) }
        var b64 = String(trimmed.dropFirst("kestrel1:".count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        // all of the owner's exits (codes made before there were two have none)
        var exits: [KestrelExit] = []
        for item in fields["x"] as? [[String: Any]] ?? [] {
            guard let c = item["c"] as? String, !c.isEmpty, let xe = item["e"] as? String,
                  let xp = xe.split(separator: ":").last, Int(xp) != nil, isHex64(item["k"]) else {
                return .failure(.missing("exit list"))
            }
            exits.append(KestrelExit(c: c, e: xe, k: item["k"] as! String))
        }
        return .success(DeviceKey(n: name, s: fields["s"] as! String, e: e, k: fields["k"] as! String,
                                  x: exits.isEmpty ? nil : exits))
    }

    /// The geph5-client config for this device: no broker, straight to the
    /// first exit, or (with `exits`) to whichever of them the engine picks.
    var clientConfig: String { clientConfig(exits: x ?? [], choice: nil) }

    /// `link`: nil (automatic: direct, disguised when direct doesn't answer)
    /// or "disguised" (always through the exits' disguised addresses).
    func clientConfig(exits: [KestrelExit], choice: String?, link: String? = nil) -> String {
        var device: [String: Any] = ["name": n, "secret": s, "stealth": true, "vpn_mtu": 1450]
        if !exits.isEmpty {
            device["exits"] = exits.map { x -> [String: String] in
                var entry = ["endpoint": x.e, "pubkey": x.k, "city": x.c]
                if let d = x.d { entry["disguise"] = d }
                return entry
            }
            if let choice { device["exit_choice"] = choice }
        }
        if let link { device["link"] = link }
        let cfg: [String: Any] = [
            "exit_constraint": ["direct": "\(e)/\(k)"],
            "allow_direct": false,
            "broker": NSNull(),
            "broker_keys": NSNull(),
            "cache": NSNull(),
            "spoof_dns": false,
            "passthrough_china": false,
            "allow_lan": false,
            // stealth: the link to the exit looks like random bytes
            // vpn_mtu: the engine's packets must fit the tunnel's MTU (1450, PacketTunnelProvider)
            "kestrel_device": device,
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
