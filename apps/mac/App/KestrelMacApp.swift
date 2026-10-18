import AppKit
import SwiftUI

@main
struct KestrelMacApp: App {
    @StateObject private var model = TunnelModel()

    var body: some Scene {
        Window("Kestrel", id: "main") {
            MacRootView()
                .environmentObject(model)
                .task {
                    if let sample = TunnelModel.launchSample {
                        model.applySample(sample)
                    } else {
                        await model.load()
                        // keep the tunnel extension installed and current
                        if model.device != nil { await TunnelExtension.shared.activate() }
                    }
                }
                .onOpenURL { url in model.setUp(from: url.absoluteString) }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(model)
                .task { if !model.loaded { await model.load() } }
        } label: {
            Image(nsImage: MenuBarIcon.image(on: model.isOn))
                .accessibilityLabel(model.isOn ? "Kestrel, connected" : "Kestrel, off")
        }
        .menuBarExtraStyle(.window)

        Settings {
            MacSettingsView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
        }
    }
}
