import XCTest

/// Drives first-launch Add Connection against the local fixture server
/// (Scripts/fixtures/serve.py). Runs with an isolated store, so it never
/// reads or changes real connections or Keychain items. Skips when the
/// fixture server isn't reachable.
final class FirstLaunchUITests: XCTestCase {
    let fixtureBase = ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"] ?? "http://127.0.0.1:8796"

    override func setUp() {
        continueAfterFailure = false
    }

    private func requireFixtureServer() throws {
        // On a device the runner has no Local Network permission.
        if ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"] != nil { return }
        let url = URL(string: "\(fixtureBase)/hls/index.m3u8")!
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: url) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        try XCTSkipUnless(reachable, "Start Scripts/fixtures/serve.py to run fixture UI tests.")
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CameraMonitorIsolatedStore", "YES"] + extra
        app.launch()
        #if os(iOS)
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }
        #endif
        return app
    }

    func testFirstLaunchAddsMJPEGConnectionAfterTesting() throws {
        try requireFixtureServer()
        let app = launch()
        XCTAssertTrue(app.staticTexts["Add your first camera"].waitForExistence(timeout: 10))
        app.buttons["discovery.manual"].firstMatch.tap()

        let kind = app.buttons["connection.kind"].firstMatch
        XCTAssertTrue(kind.waitForExistence(timeout: 5))
        kind.tap()
        app.buttons["MJPEG stream"].firstMatch.tap()
        let address = app.textFields["connection.address"]
        address.tap()
        address.typeText("\(fixtureBase)/mjpeg\n")
        app.buttons["connection.test"].tap()

        // The toolbar button switches from "Save Without Testing" once a
        // test succeeds; it stays on screen while the report is below.
        let save = app.buttons["connection.save"]
        let tested = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == 'Save'"), object: save)
        if XCTWaiter().wait(for: [tested], timeout: 20) != .completed {
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.lifetime = .keepAlways
            add(shot)
            let texts = XCTAttachment(string: app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n") + "\nAddress: \(address.value ?? "")")
            texts.lifetime = .keepAlways
            add(texts)
            XCTFail("Test Connection didn't succeed")
            return
        }
        save.tap()

        // Bare streams must not claim recording or alerts.
        XCTAssertTrue(app.staticTexts["Recording while the app is closed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["Recordings"].exists)
    }
}
