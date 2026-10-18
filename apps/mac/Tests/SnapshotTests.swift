import AppKit
import SwiftUI
import XCTest

/// Renders the Mac screens with sample data to PNGs (SNAPSHOT_DIR), so each
/// change to the app can be looked at without a Mac at hand.
@MainActor
final class SnapshotTests: XCTestCase {
    override func setUp() async throws {
        Fonts.register(from: Bundle(for: SnapshotTests.self))
    }

    private func model(connected: Bool) -> TunnelModel {
        let m = TunnelModel()
        m.applySample(connected ? .connected : .off)
        return m
    }

    /// Draws the view in a real (off-screen) window, so AppKit-backed
    /// controls render as they do on screen.
    private func render<V: View>(_ view: V, _ name: String) throws {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
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
        try png.write(to: dir.appendingPathComponent("\(name).png"))
        XCTAssertGreaterThan(size.width, 100)
    }

    func testScreens() throws {
        try render(MacRootView().environmentObject(model(connected: true)), "home-connected")
        try render(MacRootView().environmentObject(model(connected: false)), "home-off")
        let fresh = TunnelModel()
        fresh.applySample(.welcome)
        try render(MacRootView().environmentObject(fresh), "welcome")
        try render(MenuBarPanel().environmentObject(model(connected: true)), "menubar")
        try render(MacSettingsView().environmentObject(model(connected: true)), "settings")
        try render(HStack(spacing: 24) {
            Image(nsImage: MenuBarIcon.image(on: true)).renderingMode(.template).foregroundStyle(.white)
            Image(nsImage: MenuBarIcon.image(on: false)).renderingMode(.template).foregroundStyle(.white)
        }.padding(16).background(Color(white: 0.16)), "menubar-icon")
    }
}
