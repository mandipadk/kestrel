import Foundation
import NetworkExtension
import os

/// Runs the Kestrel (Geph5) client inside the packet tunnel: packets from the
/// system go into the client's IP stack, and its replies come back out.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "dev.mandip.kestrel", category: "tunnel")
    private var running = false

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        guard let proto = protocolConfiguration as? NETunnelProviderProtocol,
              let config = proto.providerConfiguration?["config"] as? String else {
            completionHandler(fail("This iPhone has no Kestrel key yet. Open Kestrel and add it."))
            return
        }
        let host = (proto.serverAddress ?? "").split(separator: ":").first.map(String.init) ?? "127.0.0.1"

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: host)
        let v4 = NEIPv4Settings(addresses: ["100.89.0.2"], subnetMasks: ["255.255.255.255"])
        v4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = v4
        // Route IPv6 in too, so nothing leaks around the tunnel. The exit is
        // IPv4-only, and apps fall back to IPv4 on their own.
        let v6 = NEIPv6Settings(addresses: ["fd89::2"], networkPrefixLengths: [128])
        v6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = v6
        settings.dnsSettings = NEDNSSettings(servers: ["1.1.1.1", "9.9.9.9"])
        settings.dnsSettings?.matchDomains = [""]
        settings.mtu = 1450

        setTunnelNetworkSettings(settings) { [weak self] error in
            guard let self else { return }
            if let error {
                completionHandler(error)
                return
            }
            let rc = config.withCString { start_client($0, -1) }
            guard rc == 0 else {
                completionHandler(self.fail("The Kestrel engine would not start (\(rc))."))
                return
            }
            self.running = true
            self.readFromSystem()
            self.startWritingToSystem()
            self.log.info("tunnel up")
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        completionHandler()
        // The engine lives for the life of the process; leave so the next
        // start gets a fresh one.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { exit(0) }
    }

    private func readFromSystem() {
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.running else { return }
            for packet in packets {
                packet.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    _ = send_pkt(base.assumingMemoryBound(to: CChar.self), Int32(raw.count))
                }
            }
            self.readFromSystem()
        }
    }

    private func startWritingToSystem() {
        let thread = Thread { [weak self] in
            var buffer = [CChar](repeating: 0, count: 65_536)
            while self?.running == true {
                let n = buffer.withUnsafeMutableBufferPointer { recv_pkt($0.baseAddress, Int32($0.count)) }
                guard n > 0, let self else { continue }
                let packet = buffer.withUnsafeBytes { Data($0.prefix(Int(n))) }
                let family = (packet.first ?? 0x40) >> 4 == 6 ? AF_INET6 : AF_INET
                self.packetFlow.writePackets([packet], withProtocols: [NSNumber(value: family)])
            }
        }
        thread.name = "kestrel-down"
        thread.stackSize = 1 << 20
        thread.start()
    }

    private func fail(_ message: String) -> NSError {
        log.error("\(message, privacy: .public)")
        return NSError(domain: "dev.mandip.kestrel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
