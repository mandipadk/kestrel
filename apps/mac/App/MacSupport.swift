import AppKit
import ServiceManagement
import SwiftUI
import SystemExtensions

extension TunnelModel {
    /// Sets this Mac up from a pasted code or a kestrel1: link.
    func setUp(from code: String) {
        switch DeviceKey.decode(code) {
        case .success(let key):
            Task {
                await TunnelExtension.shared.activate()
                await install(key, raw: code.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case .failure(let problem):
            error = problem.message
        }
    }
}

/// Kestrel for Mac ships outside the App Store, so its tunnel is a system
/// extension: macOS installs it from the app (which must be in
/// /Applications) and the owner allows it once in System Settings.
@MainActor
final class TunnelExtension: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let shared = TunnelExtension()
    static let identifier = "dev.mandip.kestrel.tunnel"

    enum State: Equatable {
        case unknown, activating, needsApproval, ready, notInApplications
        case failed(String)
    }

    @Published var state: State = .unknown
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// Installs or updates the extension; returns once macOS has answered
    /// (or is waiting for the owner's approval).
    func activate() async {
        if state == .ready { return }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else {
            state = .notInApplications
            return
        }
        await withCheckedContinuation { cont in
            waiting.append(cont)
            guard state != .activating else { return }
            state = .activating
            let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: Self.identifier, queue: .main)
            request.delegate = self
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ state: State) {
        self.state = state
        let w = waiting
        waiting = []
        w.forEach { $0.resume() }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in self.finish(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in self.finish(.ready) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        Task { @MainActor in self.finish(.failed(error.localizedDescription)) }
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }
}

/// Says what the owner has to do for the tunnel extension, if anything.
struct ExtensionNotice: View {
    @ObservedObject var ext = TunnelExtension.shared

    var body: some View {
        switch ext.state {
        case .needsApproval:
            notice("Allow Kestrel's network extension",
                   "macOS asks once. In System Settings, open General, Login Items & Extensions, Network Extensions, and turn Kestrel on.",
                   button: "Open System Settings") { TunnelExtension.openSettings() }
        case .notInApplications:
            notice("Move Kestrel to Applications",
                   "macOS only installs its network extension from there. Drag Kestrel into Applications and open it again.",
                   button: nil, action: nil)
        case .failed(let message):
            notice("The network extension didn't install", message, button: "Try again") {
                Task { await ext.activate() }
            }
        default:
            EmptyView()
        }
    }

    private func notice(_ title: String, _ detail: String, button: String?, action: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension").foregroundStyle(Ink.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.geist(14, .semibold))
                Text(detail).font(.geist(13)).foregroundStyle(Ink.muted).fixedSize(horizontal: false, vertical: true)
                if let button, let action {
                    Button(button, action: action).font(.geist(13, .medium)).padding(.top, 4)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Ink.raise, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Opens at login when the owner asks; the app is then in the menu bar.
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

/// The wing, drawn as a template image so the menu bar tints it.
enum MenuBarIcon {
    static func image(on: Bool) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            // the wing spans 20 x 14.5 of the mark's 32 units: fill the icon with it
            let unit = rect.width / 21
            ctx.translateBy(x: (rect.width - 20 * unit) / 2 - 6 * unit, y: (rect.height - 14.5 * unit) / 2 - 10.5 * unit)
            ctx.addPath(KestrelMark.wing(scale: unit).cgPath)
            ctx.setFillColor(NSColor.black.withAlphaComponent(on ? 1 : 0.45).cgColor)
            ctx.fillPath()
            return true
        }
        image.isTemplate = true
        return image
    }
}
