import AppKit
import Combine
#if SPARKLE
import Sparkle
#endif

/// Kestrel updates itself with Sparkle. CI signs each release's .dmg and the
/// appcast with an EdDSA key; the app only accepts both when they verify
/// against SUPublicEDKey in its Info.plist. Without SPARKLE (the screenshot
/// tests) this is a stand-in that never finds an update.
@MainActor
final class Updates: NSObject, ObservableObject {
    static let shared = Updates()

    /// The version a scheduled check found while the panel was closed; the
    /// panel offers it until the owner looks at it.
    @Published var waiting: String?
    @Published private(set) var canCheck = false
    @Published private(set) var lastCheck: Date?
    @Published private(set) var checksAutomatically = true
    @Published private(set) var installsAutomatically = false

    /// "1.2 (57)", the build being CI's run number
    var version: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let short = info["CFBundleShortVersionString"] as? String ?? "?"
        guard let build = info["CFBundleVersion"] as? String, !build.isEmpty else { return short }
        return "\(short) (\(build))"
    }

    #if SPARKLE
    private var controller: SPUStandardUpdaterController!
    private var watching: [AnyCancellable] = []

    private override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.canCheck = $0 }.store(in: &watching)
        updater.publisher(for: \.lastUpdateCheckDate).receive(on: RunLoop.main)
            .sink { [weak self] in self?.lastCheck = $0 }.store(in: &watching)
        updater.publisher(for: \.automaticallyChecksForUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.checksAutomatically = $0 }.store(in: &watching)
        updater.publisher(for: \.automaticallyDownloadsUpdates).receive(on: RunLoop.main)
            .sink { [weak self] in self?.installsAutomatically = $0 }.store(in: &watching)
    }

    func check() {
        // a menu bar app has to come forward for Sparkle's window to
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    func setChecksAutomatically(_ on: Bool) { controller.updater.automaticallyChecksForUpdates = on }
    func setInstallsAutomatically(_ on: Bool) { controller.updater.automaticallyDownloadsUpdates = on }
    #else
    private override init() { super.init() }
    func check() {}
    func setChecksAutomatically(_ on: Bool) { checksAutomatically = on }
    func setInstallsAutomatically(_ on: Bool) { installsAutomatically = on }

    /// Sample state for the screenshot tests.
    func applySample(waiting: String?, lastCheck: Date?) {
        self.waiting = waiting
        self.lastCheck = lastCheck
        canCheck = true
    }
    #endif
}

#if SPARKLE
/// A menu bar app has no Dock icon to bounce, so a scheduled check that finds
/// an update while Kestrel is in the background shows it in the panel
/// instead of a window over whatever the owner is doing.
extension Updates: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString
        Task { @MainActor in self.waiting = handleShowingUpdate ? nil : version }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        Task { @MainActor in self.waiting = nil }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor in self.waiting = nil }
    }
}
#endif
