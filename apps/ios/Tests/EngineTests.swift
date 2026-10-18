import XCTest

/// Runs the iOS build of the engine exactly as the tunnel does (same config,
/// same sandbox preparation, same packet calls) and proves packets make the
/// round trip through the Kestrel exit. Needs KESTREL_CODE: a setup code for
/// an enrolled test device (passed in CI as TEST_RUNNER_KESTREL_CODE).
final class EngineTests: XCTestCase {
    func testSetupCodeDecodes() throws {
        let code = try setupCode()
        guard case .success(let key) = DeviceKey.decode(code) else {
            return XCTFail("the CI setup code did not decode")
        }
        XCTAssertTrue(key.endpoint.contains(":"))
    }

    func testPacketsRoundTripThroughTheExit() throws {
        guard case .success(let key) = DeviceKey.decode(try setupCode()) else {
            return XCTFail("the CI setup code did not decode")
        }
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("kestrel-test-\(UUID())")
        let config = try Engine.prepare(configJSON: key.clientConfig, cacheDirectory: cache)
        XCTAssertTrue(config.contains("engine.db"))
        try Engine.start(configJSON: config)

        // 1. the engine reaches the exit
        var state = "unknown"
        for _ in 0..<60 {
            state = Engine.connectionState()
            if state == "Connected" { break }
            Thread.sleep(forTimeInterval: 1)
        }
        XCTAssertEqual(state, "Connected", "engine never connected; logs:\n" + Engine.recentLogs(40).joined(separator: "\n"))

        // 2. a DNS query sent as a raw IPv4/UDP packet gets a real answer back
        let answered = expectation(description: "DNS answer through the tunnel")
        let queryID: UInt16 = 0x4b37
        let reader = Thread {
            var buffer = [CChar](repeating: 0, count: 65_536)
            while true {
                let n = buffer.withUnsafeMutableBufferPointer { recv_pkt($0.baseAddress, Int32($0.count)) }
                guard n > 28 else { continue }
                let p = buffer.withUnsafeBytes { [UInt8]($0.prefix(Int(n))) }
                let ihl = Int(p[0] & 0x0f) * 4
                guard p[0] >> 4 == 4, p[9] == 17, p.count >= ihl + 8 + 12 else { continue }
                let srcPort = UInt16(p[ihl]) << 8 | UInt16(p[ihl + 1])
                let dns = Array(p[(ihl + 8)...])
                let id = UInt16(dns[0]) << 8 | UInt16(dns[1])
                let answers = UInt16(dns[6]) << 8 | UInt16(dns[7])
                if srcPort == 53, id == queryID, answers > 0 {
                    answered.fulfill()
                    return
                }
            }
        }
        reader.start()
        let packet = Packets.dnsQuery(id: queryID, name: "example.com",
                                      from: [100, 89, 0, 2], port: 53_001, to: [1, 1, 1, 1])
        let sender = Thread {
            for _ in 0..<15 {
                packet.withUnsafeBytes { raw in
                    _ = send_pkt(raw.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(raw.count))
                }
                Thread.sleep(forTimeInterval: 2)
            }
        }
        sender.start()
        wait(for: [answered], timeout: 30)
    }

    private func setupCode() throws -> String {
        let code = ProcessInfo.processInfo.environment["KESTREL_CODE"] ?? ""
        try XCTSkipIf(code.isEmpty, "set KESTREL_CODE to an enrolled test device's setup code")
        return code
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
