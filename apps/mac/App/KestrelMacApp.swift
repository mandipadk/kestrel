import AppKit
import SwiftUI

/// Kestrel for Mac lives in the menu bar (LSUIElement): a small panel to
/// connect and see status, a Settings window, and a setup window that only
/// appears until this Mac is added.
@main
struct KestrelMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var app

    var body: some Scene {
        // first, so macOS doesn't open a window at launch
        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(app.model)
                .environmentObject(app)
        } label: {
            MenuBarLabel()
                .environmentObject(app.model)
                .environmentObject(app)
        }
        .menuBarExtraStyle(.window)

        Window("Just Blocked", id: JustBlockedView.windowID) {
            JustBlockedView()
                .environmentObject(app.model)
        }
        .defaultSize(width: 460, height: 520)
        .defaultPosition(.center)

        Window("Set Up Kestrel", id: SetupView.windowID) {
            SetupView()
                .environmentObject(app.model)
        }
        .windowResizability(.contentSize)
        .windowStyle(.titleBar)
        .defaultPosition(.center)

        Settings {
            MacSettingsView()
                .environmentObject(app.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let model = TunnelModel()
    /// Bumped when something outside SwiftUI (a kestrel1: link) needs the
    /// setup window; the menu bar label opens it.
    @Published var setupRequests = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--check-extension") { return checkExtensionAndExit() }
        if CommandLine.arguments.contains("--remove-old-client") { return removeOldClientAndExit() }
        // starts Sparkle's daily check
        _ = Updates.shared
    }

    /// CI: asks sysextd to install the tunnel, as a first launch does, and
    /// says what it answered, so a refusal fails the build, not the owner's Mac.
    private func checkExtensionAndExit() {
        Task {
            await TunnelExtension.shared.activate()
            let state = TunnelExtension.shared.state
            FileHandle.standardError.write(Data("sysextd answered: \(state)\n".utf8))
            switch state {
            case .needsApproval, .ready: exit(0)
            default: exit(1)
            }
        }
    }

    /// CI: finds the old command-line client and removes it as the panel's
    /// button does. Exits 0 only if it found it and nothing of it is left.
    private func removeOldClientAndExit() {
        Task {
            let old = OldClient.shared
            old.refresh()
            let found = old.present
            let proxies = OldClient.oldProxies().map { "\($0.service) \($0.off)" }
            FileHandle.standardError.write(Data("old client found: \(found), proxies: \(proxies)\n".utf8))
            let gone = found ? await old.remove() : false
            FileHandle.standardError.write(Data("removed: \(gone) \(old.problem ?? "")\n".utf8))
            exit(found && gone ? 0 : 1)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first(where: { $0.scheme == "kestrel1" }) else { return }
        model.setUp(from: url.absoluteString)
        // a bad link leaves its problem in model.error, shown in the setup window
        if model.error != nil { setupRequests += 1 }
    }
}

/// The wing in the menu bar. It is always on screen, so it also loads the
/// model at launch and opens the setup window when this Mac has no key.
struct MenuBarLabel: View {
    @EnvironmentObject var model: TunnelModel
    @EnvironmentObject var app: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: MenuBarIcon.image(on: model.isOn))
            .accessibilityLabel(model.isOn ? "Kestrel, connected" : "Kestrel, off")
            .task {
                if let sample = TunnelModel.launchSample {
                    model.applySample(sample)
                    return
                }
                await model.load()
                if model.device == nil {
                    SetupView.open(openWindow)
                } else {
                    // keep the tunnel extension installed and current
                    await TunnelExtension.shared.activate()
                }
            }
            .onChange(of: app.setupRequests) { _, _ in SetupView.open(openWindow) }
    }
}
