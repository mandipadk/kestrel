import Foundation

/// Thin Swift wrapper over the geph5-client C interface (Tunnel/Geph.h).
enum Engine {
    /// Adds what the engine needs to run inside an iOS sandbox: a writable
    /// place for its database. Without one it falls back to a directory the
    /// extension may not be able to create.
    static func prepare(configJSON: String, cacheDirectory: URL) throws -> String {
        guard var cfg = try JSONSerialization.jsonObject(with: Data(configJSON.utf8)) as? [String: Any] else {
            throw EngineError("The saved Kestrel settings are unreadable.")
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        cfg["cache"] = cacheDirectory.appendingPathComponent("engine.db").path
        let data = try JSONSerialization.data(withJSONObject: cfg)
        return String(decoding: data, as: UTF8.self)
    }

    static func defaultCacheDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Kestrel", isDirectory: true)
    }

    static func start(configJSON: String) throws {
        let rc = configJSON.withCString { start_client($0, -1) }
        guard rc == 0 else { throw EngineError("The Kestrel engine would not start (code \(rc)).") }
    }

    /// Calls one of the engine's control methods (conn_info, recent_logs, ...).
    static func rpc(_ method: String) -> Any? {
        let req = #"{"jsonrpc":"2.0","method":"\#(method)","params":[],"id":1}"#
        var buffer = [CChar](repeating: 0, count: 1 << 20)
        let n = req.withCString { reqPtr in
            buffer.withUnsafeMutableBufferPointer { daemon_rpc(reqPtr, $0.baseAddress, Int32($0.count)) }
        }
        guard n > 0 else { return nil }
        let data = buffer.withUnsafeBytes { Data($0.prefix(Int(n))) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["result"]
    }

    /// "Connected", "Connecting" or "Disconnected", as the engine sees it.
    static func connectionState() -> String {
        switch rpc("conn_info") {
        case let s as String: return s
        case let d as [String: Any]: return d.keys.first ?? "unknown"
        default: return "unknown"
        }
    }

    static func recentLogs(_ count: Int) -> [String] {
        ((rpc("recent_logs") as? [String]) ?? []).suffix(count).map { $0 }
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
