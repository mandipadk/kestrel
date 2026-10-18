import Foundation

/// A device identity as carried by the setup QR code on the Kestrel page:
/// `kestrel1:` + base64url(JSON {n: name, s: secret, e: endpoint, k: exit key}).
struct DeviceKey: Codable, Equatable {
    let n: String
    let s: String
    let e: String
    let k: String

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
            // stealth: the link to the exit looks like random bytes
            "kestrel_device": ["name": n, "secret": s, "stealth": true],
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
