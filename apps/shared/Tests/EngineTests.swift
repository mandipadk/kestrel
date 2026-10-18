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

    /// A page over TCP, the way a browser loads one. Every packet the engine
    /// hands the system must fit the tunnel's 1450-byte MTU: macOS drops
    /// bigger ones, which once let lookups work while no page ever loaded.
    func testAPageLoadsInPacketsThatFitTheTunnel() throws {
        try EngineFixture.start(code: try setupCode())
        let host = "speed.cloudflare.com"
        let ip = try EngineFixture.resolve(host, id: 0x6c01, timeout: 30)
        let page = try EngineFixture.fetch(host: host, path: "/__down?bytes=20000", ip: ip, timeout: 30)
        XCTAssertTrue(page.body.hasPrefix("HTTP/1.1 200"), "no page: \(page.body.prefix(200))")
        XCTAssertGreaterThan(page.body.utf8.count, 20_000, "the whole 20 kB should arrive")
        XCTAssertLessThanOrEqual(page.largest, 1450, "the engine sent a \(page.largest)-byte packet into a 1450-byte tunnel")
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
        XCTAssertTrue(parsed.quantumSafe, "the session keys should come from X25519 and ML-KEM-768")
        // with the owner's exits the engine picks one; without, it uses the code's one
        let cities = EngineFixture.exits.map(\.city)
        if cities.count > 1 {
            XCTAssertTrue(cities.contains(parsed.exitCity), "on \(parsed.exitCity), not one of \(cities)")
            XCTAssertEqual(Set(parsed.exits), Set(EngineFixture.exits), "the exit should tell the device every exit")
        } else {
            XCTAssertEqual(parsed.exitCity, "Frankfurt")
        }
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
    /// The owner's exits (KESTREL_EXITS, the JSON of kestrel/exits.json), so
    /// the engine runs as an app that knows them all.
    static let exits: [KestrelExit] = {
        let raw = ProcessInfo.processInfo.environment["KESTREL_EXITS"] ?? ""
        let list = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: String]] ?? []
        return list.compactMap { e in
            guard let c = e["city"], let ep = e["endpoint"], let k = e["pubkey"] else { return nil }
            return KestrelExit(c: c, e: ep, k: k)
        }
    }()
    private static var started = false
    private static let lock = NSLock()
    private static var replies: [UInt16: (rcode: Int, answers: Int)] = [:]
    private static var addresses: [UInt16: [UInt8]] = [:]
    /// TCP packets the engine sent to our test port
    private static var tcp: [[UInt8]] = []
    static let tcpPort: UInt16 = 40_123

    static func start(code: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !started else { return }
        guard case .success(let key) = DeviceKey.decode(code) else {
            throw EngineError("the CI setup code did not decode")
        }
        XCTAssertTrue(key.clientConfig.contains("\"stealth\":true"))
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID())")
        let config = try Engine.prepare(configJSON: key.clientConfig(exits: exits, choice: nil), cacheDirectory: cache)
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
                if p[0] >> 4 == 4, p[9] == 6, p.count >= ihl + 20,
                   UInt16(p[ihl + 2]) << 8 | UInt16(p[ihl + 3]) == tcpPort {
                    lock.lock()
                    tcp.append(p)
                    lock.unlock()
                    continue
                }
                guard p[0] >> 4 == 4, p[9] == 17, p.count >= ihl + 8 + 12 else { continue }
                let srcPort = UInt16(p[ihl]) << 8 | UInt16(p[ihl + 1])
                guard srcPort == 53 else { continue }
                let dns = Array(p[(ihl + 8)...])
                let id = UInt16(dns[0]) << 8 | UInt16(dns[1])
                let rcode = Int(dns[3] & 0x0f)
                let answers = Int(UInt16(dns[6]) << 8 | UInt16(dns[7]))
                // the first A record: a compressed name, type A, class IN, TTL, length 4
                var address: [UInt8]?
                var i = 12
                while address == nil, i + 16 <= dns.count {
                    let isA: Bool = dns[i] == 0xc0 && dns[i + 2] == 0 && dns[i + 3] == 1 && dns[i + 4] == 0 && dns[i + 5] == 1
                    if isA, dns[i + 10] == 0, dns[i + 11] == 4 { address = Array(dns[(i + 12)..<(i + 16)]) }
                    i += 1
                }
                lock.lock()
                replies[id] = (rcode, answers)
                if let address { addresses[id] = address }
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

    /// The first IPv4 address the exit's resolver gives for `name`.
    static func resolve(_ name: String, id: UInt16, timeout: TimeInterval) throws -> [UInt8] {
        _ = try lookup(name, id: id, timeout: timeout)
        lock.lock()
        defer { lock.unlock() }
        guard let ip = addresses[id] else { throw EngineError("no A record for \(name)") }
        return ip
    }

    private static func send(_ packet: Data) {
        packet.withUnsafeBytes { raw in
            _ = send_pkt(raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
        }
    }

    /// Opens a TCP connection through the engine as a browser's packets would,
    /// sends a plain HTTP GET, and collects what comes back until the server
    /// closes. Answers the response and the largest packet the engine sent.
    static func fetch(host: String, path: String, ip: [UInt8], timeout: TimeInterval) throws -> (body: String, largest: Int) {
        let me: [UInt8] = [100, 89, 0, 2]
        let mySeq: UInt32 = 0x1000
        func taken() -> [[UInt8]] {
            lock.lock()
            defer { lock.unlock() }
            let t = tcp
            tcp = []
            return t
        }
        _ = taken()
        let deadline = Date().addingTimeInterval(timeout)
        // handshake
        var theirSeq: UInt32?
        var lastSyn = Date.distantPast
        while theirSeq == nil, Date() < deadline {
            if Date().timeIntervalSince(lastSyn) > 2 {
                send(Packets.tcp(from: me, port: tcpPort, to: ip, port: 80, seq: mySeq, ack: 0, flags: 0x02, mss: 1410))
                lastSyn = Date()
            }
            for p in taken() where Packets.tcpFlags(p) & 0x12 == 0x12 { theirSeq = Packets.tcpSeq(p) }
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard var next = theirSeq.map({ $0 &+ 1 }) else { throw EngineError("no SYN-ACK from \(host)") }
        // the handshake's ACK on its own: the engine's stack drops data that rides on it
        send(Packets.tcp(from: me, port: tcpPort, to: ip, port: 80, seq: mySeq &+ 1, ack: next, flags: 0x10))
        let request = Array("GET \(path) HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n".utf8)
        let requestEnd = mySeq &+ 1 &+ UInt32(request.count)
        // send the request until it is acknowledged (as a kernel retransmits),
        // then collect the reply in order, acknowledging as we go, until FIN
        var body: [UInt8] = []
        var largest = 0
        var done = false
        var acked = false
        var lastSent = Date.distantPast
        while !done, Date() < deadline {
            if !acked, Date().timeIntervalSince(lastSent) > 1 {
                send(Packets.tcp(from: me, port: tcpPort, to: ip, port: 80, seq: mySeq &+ 1, ack: next, flags: 0x18, payload: request))
                lastSent = Date()
            }
            for p in taken() {
                largest = max(largest, p.count)
                if Packets.tcpAck(p) == requestEnd { acked = true }
                let payload = Packets.tcpPayload(p)
                if Packets.tcpSeq(p) == next, !payload.isEmpty {
                    body += payload
                    next = next &+ UInt32(payload.count)
                }
                if Packets.tcpFlags(p) & 0x01 != 0, Packets.tcpSeq(p) &+ UInt32(payload.count) == next {
                    next = next &+ 1
                    done = true
                }
            }
            send(Packets.tcp(from: me, port: tcpPort, to: ip, port: 80, seq: requestEnd, ack: next, flags: 0x10))
            Thread.sleep(forTimeInterval: 0.05)
        }
        guard !body.isEmpty else { throw EngineError("no response from \(host)") }
        return (String(decoding: body, as: UTF8.self), largest)
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

    /// An IPv4/TCP packet (window 65535; MSS option on a SYN).
    static func tcp(from src: [UInt8], port sport: UInt16, to dst: [UInt8], port dport: UInt16,
                    seq: UInt32, ack: UInt32, flags: UInt8, mss: UInt16? = nil, payload: [UInt8] = []) -> Data {
        func be16(_ v: UInt16) -> [UInt8] { [UInt8(v >> 8), UInt8(v & 0xff)] }
        func be32(_ v: UInt32) -> [UInt8] { be16(UInt16(v >> 16)) + be16(UInt16(v & 0xffff)) }
        var options: [UInt8] = []
        if let mss { options = [2, 4] + be16(mss) }
        let offset = UInt8((20 + options.count) / 4) << 4
        var seg: [UInt8] = be16(sport) + be16(dport)
        seg += be32(seq)
        seg += be32(ack)
        seg += [offset, flags, 0xff, 0xff, 0, 0, 0, 0]
        seg += options
        seg += payload
        var pseudo: [UInt8] = src + dst
        pseudo += [0, 6] + be16(UInt16(seg.count))
        pseudo += seg
        if pseudo.count % 2 == 1 { pseudo.append(0) }
        let sum = checksum(pseudo)
        seg[16] = UInt8(sum >> 8)
        seg[17] = UInt8(sum & 0xff)
        let total = UInt16(20 + seg.count)
        var ip: [UInt8] = [0x45, 0] + be16(total)
        ip += [0x43, 0x21, 0x40, 0, 64, 6, 0, 0]
        ip += src + dst
        let ipSum = checksum(ip)
        ip[10] = UInt8(ipSum >> 8)
        ip[11] = UInt8(ipSum & 0xff)
        return Data(ip + seg)
    }

    private static func tcpOffset(_ p: [UInt8]) -> Int { Int(p[0] & 0x0f) * 4 }
    static func tcpFlags(_ p: [UInt8]) -> UInt8 { p[tcpOffset(p) + 13] }
    static func tcpSeq(_ p: [UInt8]) -> UInt32 { be32(p, at: tcpOffset(p) + 4) }
    static func tcpAck(_ p: [UInt8]) -> UInt32 { be32(p, at: tcpOffset(p) + 8) }
    private static func be32(_ p: [UInt8], at o: Int) -> UInt32 {
        let high = UInt32(p[o]) << 24 | UInt32(p[o + 1]) << 16
        let low = UInt32(p[o + 2]) << 8 | UInt32(p[o + 3])
        return high | low
    }
    static func tcpPayload(_ p: [UInt8]) -> [UInt8] {
        let ihl = tcpOffset(p)
        let length = Int(p[2]) << 8 | Int(p[3])
        let total = min(p.count, length)
        let start = ihl + Int(p[ihl + 12] >> 4) * 4
        return start < total ? Array(p[start..<total]) : []
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
