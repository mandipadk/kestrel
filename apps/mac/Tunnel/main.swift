import Foundation
import NetworkExtension

// A system extension runs as its own process: hand it to NetworkExtension,
// which creates the PacketTunnelProvider when a tunnel starts.
autoreleasepool {
    NEProvider.startSystemExtensionMode()
}
dispatchMain()
