import AppKit
import ServiceManagement
import SwiftUI

extension TunnelModel {
    /// Sets this Mac up from a pasted code or a kestrel1: link.
    func setUp(from code: String) {
        switch DeviceKey.decode(code) {
        case .success(let key):
            Task { await install(key, raw: code.trimmingCharacters(in: .whitespacesAndNewlines)) }
        case .failure(let problem):
            error = problem.message
        }
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
