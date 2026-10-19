import AppKit
import SwiftUI
import XCTest

/// Renders the Mac screens with sample data to PNGs (SNAPSHOT_DIR), in light
/// and dark, so each change to the app can be looked at without a Mac at hand.
@MainActor
final class SnapshotTests: XCTestCase {
    override func setUp() async throws {
        Fonts.register(from: Bundle(for: SnapshotTests.self))
    }

    private func model(_ state: TunnelModel.SampleState) -> TunnelModel {
        let m = TunnelModel()
        m.applySample(state)
        return m
    }

    /// Draws the view in a real (off-screen) window, so AppKit-backed
    /// controls render as they do on screen. The tests have no asset
    /// catalog, so the app's accent is applied as a tint.
    private func render<V: View>(_ view: V, _ name: String) throws {
        for (suffix, appearance, scheme) in [("dark", NSAppearance.Name.darkAqua, ColorScheme.dark),
                                             ("light", .aqua, .light)] {
            let host = NSHostingView(rootView: view
                .tint(Ink.accent)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, scheme))
            host.appearance = NSAppearance(named: appearance)
            let size = host.fittingSize
            host.frame = NSRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
                return XCTFail("could not render \(name)")
            }
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no PNG for \(name)") }
            let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SNAPSHOT_DIR"] ?? NSTemporaryDirectory())
                .appendingPathComponent("mac")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try png.write(to: dir.appendingPathComponent("\(name)-\(suffix).png"))
            XCTAssertGreaterThan(size.width, 40)
        }
    }

    func testScreens() throws {
        try render(MenuBarPanel().environmentObject(model(.connected)), "panel-connected")
        try render(MenuBarPanel().environmentObject(model(.off)), "panel-off")
        try render(MenuBarPanel().environmentObject(model(.welcome)), "panel-not-set-up")
        Updates.shared.applySample(waiting: "1.3", lastCheck: Date().addingTimeInterval(-3 * 3600))
        try render(MenuBarPanel().environmentObject(model(.connected)), "panel-update-ready")
        Updates.shared.applySample(waiting: nil, lastCheck: Date().addingTimeInterval(-3 * 3600))
        TunnelExtension.shared.state = .needsApproval
        try render(MenuBarPanel().environmentObject(model(.off)), "panel-approve-extension")
        try render(SetupView().environmentObject(model(.welcome)), "setup")
        TunnelExtension.shared.state = .unknown
        try render(GeneralSettings().environmentObject(model(.connected)).frame(width: 500), "settings-general")
        try render(WiFiSettings().environmentObject(model(.connected)).frame(width: 500), "settings-wifi")
        try render(ThisMacSettings().environmentObject(model(.connected)).frame(width: 500), "settings-this-mac")
        try render(JustBlockedView().environmentObject(model(.connected)).frame(width: 460, height: 480), "just-blocked")
        try render(HStack(spacing: 24) {
            Image(nsImage: MenuBarIcon.image(on: true)).renderingMode(.template).foregroundStyle(.primary)
            Image(nsImage: MenuBarIcon.image(on: false)).renderingMode(.template).foregroundStyle(.primary)
        }.padding(16), "menubar-icon")
    }
}
