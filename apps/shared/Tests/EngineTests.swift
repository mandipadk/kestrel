import XCTest

/// Runs the engine (iPhone or Mac build) exactly as the tunnel does (same
/// config, same sandbox preparation, same packet calls) and proves packets
/// make the round trip through the Kestrel exit, over the stealth link, with
/// Shield answering for trackers. Needs KESTREL_CODE: a setup code for an
/// enrolled test device (passed in CI as TEST_RUNNER_KESTREL_CODE).
final class EngineTests: XCTestCase {
    func testSetupCodeDecodes() throws {
        let code = try setupCode()
        guard case .success(let key) = DeviceKey.decode(code) else {
            return XCTFail("the CI setup code did not decode")
        }
        XCTAssertTrue(key.endpoint.contains(":"))
    }

    func testPacketsRoundTripThroughTheExit() throws {
        try EngineFixture.start(code: try setupCode())
        // a DNS query sent as a raw IPv4/UDP packet gets a real answer back
        let reply = try EngineFixture.lookup("example.com", id: 0x4b37, timeout: 30)
        XCTAssertEqual(reply.rcode, 0)
        XCTAssertGreaterThan(reply.answers, 0)
    }

    func testShieldAnswersTrackersAtOnce() throws {
        try EngineFixture.start(code: try setupCode())
        // the exit answers a tracker lookup itself, with "no such name"
        let reply = try EngineFixture.lookup("stats.g.doubleclick.net", id: 0x5a11, timeout: 30)
        XCTAssertEqual(reply.rcode, 3, "expected NXDOMAIN from Shield")
        XCTAssertEqual(reply.answers, 0)
    }

    func testTheExitReportsOnThisDeviceOverTheStealthLink() throws {
        let code = try setupCode()
        try EngineFixture.start(code: code)
        guard case .success(let key) = DeviceKey.decode(code) else { return XCTFail("bad code") }
        var report: [String: Any]?
        var lastError = ""
        for _ in 0..<10 {
            switch Engine.exitReport("status") {
            case .success(let r): report = r
            case .failure(let e): lastError = e.message
            }
            if report != nil { break }
            Thread.sleep(forTimeInterval: 2)
        }
        guard let report, let parsed = ExitReport(json: report) else {
            return XCTFail("no report from the exit: \(lastError)")
        }
        XCTAssertEqual(parsed.device, key.name)
        XCTAssertTrue(parsed.stealth, "the engine should reach the exit over the stealth link")
        XCTAssertEqual(parsed.exitCity, "Frankfurt")
        XCTAssertEqual(parsed.shield.hourly.count, 24)
    }

    private func setupCode() throws -> String {
        let code = ProcessInfo.processInfo.environment["KESTREL_CODE"] ?? ""
        try XCTSkipIf(code.isEmpty, "set KESTREL_CODE to an enrolled test device's setup code")
        return code
    }
}

/// The engine runs once per test process; every test shares it.
enum EngineFixture {
    private static var started = false
    private static let lock = NSLock()
    private static var replies: [UInt16: (rcode: Int, answers: Int)] = [:]

    static func start(code: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard case .success(let key) = DeviceKey.decode(code) else {
            throw EngineError("the CI setup code did not decode")
        }
        XCTAssertTrue(key.clientConfig.contains("\"stealth\":true"))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID())")
        let config = try Engine.prepare(configJSON: key.clientConfig, cacheDirectory: cache)
        XCTAssertTrue(config.contains("engine.db"))
        try Engine.start(configJSON: config)
        var state = "unknown"
        for _ in 0..<60 {
            state = Engine.connectionState()
            if state == "Connected" { break }
            Thread.sleep(forTimeInterval: 1)
        }
        guard state == "Connected" else {
            throw EngineError("engine never connected; logs:\n" + Engine.recentLogs(40).joined(separator: "\n"))
        }
        started = true
        // one reader hands each DNS reply to whoever asked for its id
        let reader = Thread {
            var buffer = [CChar](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBufferPointer { recv_pkt($0.baseAddress, Int32($0.count)) }
                guard n > 28 else { continue }
                let p = buffer.withUnsafeBytes { [UInt8]($0.prefix(Int(n))) }
                let ihl = Int(p[0] & 0x0f) * 4
                guard p[0] >> 4 == 4, p[9] == 17, p.count >= ihl + 8 + 12 else { continue }
                let srcPort = UInt16(p[ihl]) << 8 | UInt16(p[ihl + 1])
                guard srcPort == 53 else { continue }
                let dns = Array(p[(ihl + 8)...])
                let id = UInt16(dns[0]) << 8 | UInt16(dns[1])
                let rcode = Int(dns[3] & 0x0f)
                let answers = Int(UInt16(dns[6]) << 8 | UInt16(dns[7]))
                lock.lock()
                replies[id] = (rcode, answers)
                lock.unlock()
            }
        }
        reader.start()
    }

    /// Sends a DNS query for `name` into the tunnel (resending every two
    /// seconds) and waits for the reply.
    static func lookup(_ name: String, id: UInt16, timeout: TimeInterval) throws -> (rcode: Int, answers: Int) {
        let packet = Packets.dnsQuery(id: id, name: name, from: [100, 89, 0, 2], port: 53_000 + id % 1000, to: [1, 1, 1, 1])
        let deadline = Date().addingTimeInterval(timeout)
        var lastSent = Date.distantPast
        while Date() < deadline {
            lock.lock()
            let reply = replies[id]
            lock.unlock()
            if let reply { return reply }
            if Date().timeIntervalSince(lastSent) > 2 {
                packet.withUnsafeBytes { raw in
                    _ = send_pkt(raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
                }
                lastSent = Date()
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw EngineError("no DNS reply for \(name) within \(Int(timeout))s")
    }
}

enum Packets {
    /// An IPv4/UDP packet carrying a DNS A query.
    static func dnsQuery(id: UInt16, name: String, from src: [UInt8], port: UInt16, to dst: [UInt8]) -> Data {
        var dns: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in name.split(separator: ".") {
            dns.append(UInt8(label.utf8.count))
            dns.append(contentsOf: label.utf8)
        }
        dns += [0, 0, 1, 0, 1] // end, type A, class IN

        let udpLength = 8 + dns.count
        var udp: [UInt8] = [UInt8(port >> 8), UInt8(port & 0xff), 0, 53,
                            UInt8(udpLength >> 8), UInt8(udpLength & 0xff), 0, 0] + dns
        var pseudo = src + dst + [0, 17, UInt8(udpLength >> 8), UInt8(udpLength & 0xff)] + udp
        if pseudo.count % 2 == 1 { pseudo.append(0) }
        var sum = checksum(pseudo)
        if sum == 0 { sum = 0xffff }
        udp[6] = UInt8(sum >> 8)
        udp[7] = UInt8(sum & 0xff)

        let total = 20 + udp.count
        var ip: [UInt8] = [0x45, 0, UInt8(total >> 8), UInt8(total & 0xff), 0x12, 0x34, 0x40, 0,
                           64, 17, 0, 0] + src + dst
        let ipSum = checksum(ip)
        ip[10] = UInt8(ipSum >> 8)
        ip[11] = UInt8(ipSum & 0xff)
        return Data(ip + udp)
    }

    static func checksum(_ bytes: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < bytes.count {
            sum += UInt32(bytes[i]) << 8 | UInt32(bytes[i + 1])
            i += 2
        }
        if i < bytes.count { sum += UInt32(bytes[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }
}
