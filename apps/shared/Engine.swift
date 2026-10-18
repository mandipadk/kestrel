import Foundation

/// Thin Swift wrapper over the geph5-client C interface (Geph.h).
enum Engine {
    /// Adds what the engine needs to run inside an Apple sandbox: a writable
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
    /// Blocks until the engine answers.
    static func rpc(_ method: String, _ params: [Any] = []) -> Any? {
        guard let paramData = try? JSONSerialization.data(withJSONObject: params) else { return nil }
        let req = #"{"jsonrpc":"2.0","method":"\#(method)","params":\#(String(decoding: paramData, as: UTF8.self)),"id":1}"#
        var buffer = [CChar](repeating: 0, count: 1 << 20)
        let n = req.withCString { reqPtr in
            buffer.withUnsafeMutableBufferPointer { daemon_rpc(reqPtr, $0.baseAddress, Int32($0.count)) }
        }
        guard n > 0 else { return nil }
        // The reply is a C string: drop the trailing NUL before parsing.
        let data = buffer.withUnsafeBytes { Data($0.prefix(Int(n))) }.filter { $0 != 0 }
        guard let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // A method that fails answers a JSON-RPC error instead of a result.
        if let error = reply["error"] as? [String: Any] {
            return EngineError(error["message"] as? String ?? "The engine reported an error.")
        }
        return reply["result"]
    }

    /// "Connected", "Connecting" or "Disconnected", as the engine sees it
    /// (conn_info answers {"state": ...}).
    static func connectionState() -> String {
        (rpc("conn_info") as? [String: Any])?["state"] as? String ?? "unknown"
    }

    static func recentLogs(_ count: Int) -> [String] {
        ((rpc("recent_logs") as? [String]) ?? []).suffix(count).map { $0 }
    }

    /// Asks the exit about this device, through the tunnel: "status",
    /// "shield-pause" or "shield-resume". Answers the exit's JSON report.
    static func exitReport(_ request: String) -> Result<[String: Any], EngineError> {
        switch rpc("kestrel_exit", [request]) {
        case let report as [String: Any]: return .success(report)
        case let err as EngineError: return .failure(err)
        default: return .failure(EngineError("The engine gave no answer."))
        }
    }
}

struct EngineError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
