import XCTest

/// Live playback against the local fixtures (Scripts/fixtures/serve.py and
/// rtsp.sh). On a physical iPhone/iPad, start both with --host 0.0.0.0 /
/// RTSP_FIXTURE_LISTEN=0.0.0.0 and pass the Mac's LAN address:
///   TEST_RUNNER_CAMERA_MONITOR_FIXTURE_BASE=http://<mac-ip>:8796 xcodebuild test …
/// Every run uses an isolated store, never real connections.
final class PlaybackUITests: XCTestCase {
    let fixtureBase = ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"] ?? "http://127.0.0.1:8796"
    var host: String { URL(string: fixtureBase)!.host! }

    override func setUp() {
        continueAfterFailure = false
    }

    func requireFixtures() throws {
        // On a physical device the test runner has no Local Network
        // permission; the app does. Trust an explicitly passed base there.
        if ProcessInfo.processInfo.environment["CAMERA_MONITOR_FIXTURE_BASE"] != nil { return }
        let semaphore = DispatchSemaphore(value: 0)
        var reachable = false
        URLSession.shared.dataTask(with: URL(string: "\(fixtureBase)/hls/index.m3u8")!) { _, response, _ in
            reachable = (response as? HTTPURLResponse)?.statusCode == 200
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        try XCTSkipUnless(reachable, "Start Scripts/fixtures/serve.py (and rtsp.sh) to run playback UI tests.")
    }

    func post(_ path: String) {
        var request = URLRequest(url: URL(string: fixtureBase + path)!)
        request.httpMethod = "POST"
        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in semaphore.signal() }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    @discardableResult
    func launch(_ connections: String, open index: Int? = 0, extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-CameraMonitorIsolatedStore", "YES", "-CameraMonitorFixtureConnections", connections, "-CameraMonitorDiagnostics", "YES"] + extra
        if let index { app.launchArguments += ["-CameraMonitorOpenCamera", "\(index)"] }
        app.launch()
        allowLocalNetworkIfAsked()
        return app
    }

    /// The app being tested needs Local Network access to reach the
    /// fixtures; accept its own permission prompt if iOS shows it.
    func allowLocalNetworkIfAsked() {
        #if os(iOS)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 6) { allow.tap() }
        #endif
    }

    func player(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    func waitUntil(_ element: XCUIElement, value: String, timeout: TimeInterval, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            let app = XCUIApplication()
            screenshot(app, "Failure: waiting for \(value)")
            let texts = XCTAttachment(string: app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: "\n"))
            texts.name = "Visible text"
            texts.lifetime = .keepAlways
            add(texts)
        }
        XCTAssertEqual(result, .completed, "\(element) never became \(value)", file: file, line: line)
    }

    func screenshot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertPlays(_ name: String, kind: String, url: String, player id: String) throws {
        try requireFixtures()
        let app = launch("\(name)|\(kind)|\(url)")
        waitUntil(player(app, id), value: "playing", timeout: 30)
        sleep(3)
        screenshot(app, name)
        waitUntil(player(app, id), value: "playing", timeout: 5)
    }

    func testHLSPlays() throws { try assertPlays("HLS", kind: "hls", url: "\(fixtureBase)/hls/index.m3u8", player: "player.hls") }
    func testHLSWithBasicAuthPlays() throws { try assertPlays("HLS auth", kind: "hls", url: "http://fixture:fixture-pass@\(host):8796/hls-auth/index.m3u8", player: "player.hls") }
    func testMJPEGPlays() throws { try assertPlays("MJPEG", kind: "mjpeg", url: "\(fixtureBase)/mjpeg", player: "player.mjpeg") }
    func testRTSPH264Plays() throws { try assertPlays("RTSP H.264", kind: "rtsp", url: "rtsp://\(host):8554/fixture", player: "player.rtsp") }
    func testRTSPH265Plays() throws { try assertPlays("RTSP H.265", kind: "rtsp", url: "rtsp://\(host):8554/fixture-h265", player: "player.rtsp") }
    func testRTSPWithAuthPlays() throws { try assertPlays("RTSP auth", kind: "rtsp", url: "rtsp://fixture:fixture-pass@\(host):8554/secure", player: "player.rtsp") }
    func testGo2RTCStreamPlays() throws { try assertPlays("go2rtc", kind: "go2rtc", url: "\(fixtureBase)/go2rtc", player: "player.rtsp") }
    func testONVIFCameraPlays() throws { try assertPlays("ONVIF", kind: "onvif", url: "http://fixture:fixture-pass@\(host):8796", player: "player.rtsp") }
    func testWorkspaceDashboardPlays() throws {
        try requireFixtures()
        // Token-based servers must use https except on loopback, so the
        // plain-http fake only works when the fixture runs on this device.
        try XCTSkipUnless(["127.0.0.1", "localhost"].contains(host), "The http fixture dashboard is refused on a LAN address by design.")
        let app = launch("Pi|workspaceCamera|\(fixtureBase)/workspace|fixture-token")
        waitUntil(player(app, "player.hls"), value: "playing", timeout: 30)
        screenshot(app, "Workspace dashboard")
    }

    /// A real Home Services server (never fixtures): live view and its
    /// recordings list, read-only. Needs CAMERA_MONITOR_HS_URL and
    /// CAMERA_MONITOR_HS_TOKEN (delete the result bundle afterwards).
    func testRealHomeServicesLiveAndRecordings() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CAMERA_MONITOR_HS_URL"], let token = env["CAMERA_MONITOR_HS_TOKEN"] else {
            throw XCTSkip("Set CAMERA_MONITOR_HS_URL and CAMERA_MONITOR_HS_TOKEN to test a real Home Services server.")
        }
        let app = launch("Home Services|homeServices|\(url)|\(token)", open: 1)
        waitUntil(player(app, "player.hls"), value: "playing", timeout: 45)
        sleep(4)
        screenshot(app, "Home Services live")
        let recordings = app.buttons["detail.recordings"].firstMatch
        XCTAssertTrue(recordings.waitForExistence(timeout: 10))
        recordings.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Continuous' OR label CONTAINS 'Motion'")).firstMatch.waitForExistence(timeout: 20))
        screenshot(app, "Home Services recordings")
    }

    #if os(macOS)
    /// This Mac's built-in or USB camera (needs camera permission once).
    func testLocalCameraPreview() throws {
        let app = launch("This Mac|localDevice|")
        waitUntil(player(app, "player.local"), value: "playing", timeout: 30)
        screenshot(app, "Local camera")
    }
    #endif

    /// Watches the real server's live view through an announced server
    /// outage (e.g. a reboot) and requires it to recover without help.
    func testRealHomeServicesRecoversFromServerOutage() throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["CAMERA_MONITOR_HS_URL"], let token = env["CAMERA_MONITOR_HS_TOKEN"], env["CAMERA_MONITOR_EXPECT_OUTAGE"] != nil else {
            throw XCTSkip("Only during an announced outage of a real server.")
        }
        let app = launch("Home Services|homeServices|\(url)|\(token)", open: 1)
        waitUntil(player(app, "player.hls"), value: "playing", timeout: 60)
        screenshot(app, "Before outage")
        waitUntil(player(app, "player.hls"), value: "not playing", timeout: 1500)
        let lost = Date()
        screenshot(app, "During outage")
        waitUntil(player(app, "player.hls"), value: "playing", timeout: 900)
        let note = XCTAttachment(string: "Recovered \(Int(Date().timeIntervalSince(lost))) s after playback stopped")
        note.lifetime = .keepAlways
        add(note)
        sleep(5)
        screenshot(app, "After outage")
    }

    func testWrongRTSPPasswordIsReportedNotRetriedForever() throws {
        try requireFixtures()
        let app = launch("RTSP wrong|rtsp|rtsp://fixture:wrong@\(host):8554/secure")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'password'")).firstMatch.waitForExistence(timeout: 20))
        screenshot(app, "RTSP wrong password")
    }

    /// The fixture's flaky stream drops for 12 s every 32 s; the player
    /// must notice and reconnect by itself.
    func testReconnectsAfterNetworkOutage() throws {
        try requireFixtures()
        let app = launch("MJPEG|mjpeg|\(fixtureBase)/mjpeg-flaky")
        let mjpeg = player(app, "player.mjpeg")
        waitUntil(mjpeg, value: "playing", timeout: 45)
        waitUntil(mjpeg, value: "not playing", timeout: 40)
        screenshot(app, "During outage")
        waitUntil(player(app, "player.mjpeg"), value: "playing", timeout: 60)
        screenshot(app, "Recovered")
    }

    #if os(iOS)
    /// Live view stops in the background and resumes on return.
    func testBackgroundAndForegroundResumesRTSP() throws {
        try requireFixtures()
        let app = launch("RTSP|rtsp|rtsp://\(host):8554/fixture")
        waitUntil(player(app, "player.rtsp"), value: "playing", timeout: 30)
        XCUIDevice.shared.press(.home)
        sleep(8)
        app.activate()
        waitUntil(player(app, "player.rtsp"), value: "playing", timeout: 30)
        screenshot(app, "Resumed after background")
    }
    #endif

    /// Plays RTSP for `CAMERA_MONITOR_SOAK_SECONDS` (default 120) and checks
    /// the memory footprint doesn't keep growing.
    func testRTSPMemoryStaysFlat() throws {
        try requireFixtures()
        let seconds = Int(ProcessInfo.processInfo.environment["CAMERA_MONITOR_SOAK_SECONDS"] ?? "120") ?? 120
        let app = launch("RTSP|rtsp|rtsp://\(host):8554/fixture")
        waitUntil(player(app, "player.rtsp"), value: "playing", timeout: 30)
        let memory = app.descendants(matching: .any)["diagnostics.memory"].firstMatch
        sleep(10)
        let start = Int(memory.value as? String ?? "") ?? -1
        var samples = [start]
        for _ in 0..<(seconds / 30) {
            sleep(30)
            samples.append(Int(memory.value as? String ?? "") ?? -1)
        }
        let end = samples.last ?? -1
        let note = XCTAttachment(string: "Memory footprint MB every 30 s: \(samples)")
        note.lifetime = .keepAlways
        add(note)
        XCTAssertGreaterThan(start, 0)
        XCTAssertLessThan(end - start, 40, "memory grew from \(start) MB to \(end) MB: \(samples)")
        waitUntil(player(app, "player.rtsp"), value: "playing", timeout: 5)
    }

    /// Range selection and batch deletion against the fake Frigate's
    /// disposable events; active and retained events must survive.
    func testFrigateRangeDeletion() throws {
        try requireFixtures()
        post("/_fixture/reset")
        let app = launch("Frigate|frigate|\(fixtureBase)/frigate", open: 1)
        let recordings = app.buttons["detail.recordings"].firstMatch
        XCTAssertTrue(recordings.waitForExistence(timeout: 20))
        recordings.tap()
        XCTAssertTrue(app.buttons["recordings.select"].waitForExistence(timeout: 15))
        app.buttons["recordings.select"].tap()
        app.buttons["recordings.range"].tap()
        app.buttons["Last 24 hours"].tap()
        app.buttons["range.select"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Selected 7 of 9'")).firstMatch.waitForExistence(timeout: 15))
        screenshot(app, "Frigate range selected")
        app.buttons["recordings.deleteSelected"].tap()
        let confirm = app.buttons["Delete 7 Recordings"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Deleted 7 recordings'")).firstMatch.waitForExistence(timeout: 15))
        screenshot(app, "Frigate range deleted")
    }
}
