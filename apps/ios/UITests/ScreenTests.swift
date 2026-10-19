import XCTest

/// Launches the app in sample mode and keeps a screenshot of each screen
/// (exported from the test results in CI for review).
final class ScreenTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    private func shoot(_ name: String, _ args: [String]) {
        let app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        sleep(2)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        app.terminate()
    }

    func testScreens() {
        shoot("home-connected", ["-KestrelSample", "connected"])
        shoot("home-off", ["-KestrelSample", "off"])
        shoot("welcome", ["-KestrelSample", "welcome"])
        shoot("settings", ["-KestrelSample", "connected", "-KestrelShowSettings"])
        shoot("just-blocked", ["-KestrelSample", "connected", "-KestrelShowBlocked"])
    }
}
