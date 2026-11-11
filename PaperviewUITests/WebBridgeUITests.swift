import XCTest

final class WebBridgeUITests: XCTestCase {
    private func fixture() throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        for key in ["ORIGIN", "ACCOUNT_ORIGIN", "EMAIL", "PASSWORD", "SPACE", "PAPER", "SIGNUP_EMAIL", "SIGNUP_PASSWORD", "SIGNUP_ROUTE"] {
            guard env["PAPERVIEW_TEST_" + key]?.isEmpty == false else { throw XCTSkip("Missing isolated fixture: \(key)") }
        }
        return env
    }

    func testLiveBoardToNativeReaderAndBack() throws {
        XCUIDevice.shared.orientation = .portrait
        let env = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["--space-test-origin=" + env["PAPERVIEW_TEST_ORIGIN"]!, "--space-test-route=/login", "--accounts-test-origin=" + env["PAPERVIEW_TEST_ACCOUNT_ORIGIN"]!, "--space-test-clear-web-data"]
        app.launch()
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 20))
        let email = web.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout: 20))
        email.tap(); email.typeText(env["PAPERVIEW_TEST_EMAIL"]!)
        let password = web.secureTextFields.firstMatch
        password.tap(); password.typeText(env["PAPERVIEW_TEST_PASSWORD"]!)
        web.buttons["Sign in"].tap()
        let space = web.buttons[env["PAPERVIEW_TEST_SPACE"]!]
        XCTAssertTrue(space.waitForExistence(timeout: 20)); space.tap()
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
        // Fixture contract: a single paper card centered by Fit to content.
        let canvas = web.descendants(matching: .any)["Drawing canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        web.buttons["Show space controls"].tap()
        // The canvas element exists before the WASM engine exposes its controls.
        let fit = web.buttons["Fit to content (F)"]
        XCTAssertTrue(fit.waitForExistence(timeout: 30))
        fit.tap()
        recordScreenshot(name: "WASM board")
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        XCTAssertFalse(web.isHittable)
        XCTAssertTrue(app.scrollViews["paper.toolbar"].exists)
        let pageCount = app.descendants(matching: .any)["reader.page-count"].firstMatch
        XCTAssertTrue(pageCount.waitForExistence(timeout: 20))
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (pageCount.value as? String) == "1 of 4"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed)
        recordScreenshot(name: "Native reader")
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 10), .completed)
        XCTAssertTrue(app.scrollViews["paper.toolbar"].exists)
        // Interact in the new orientation so XCTest waits for UIKit's rotation
        // transition, not merely the window frame changing before the animation.
        app.buttons["reader.thinner"].tap()
        app.buttons["reader.thicker"].tap()
        recordScreenshot(name: "Native reader landscape")
        XCUIDevice.shared.orientation = .portrait
        let portrait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.height > app.frame.width
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [portrait], timeout: 10), .completed)
        let before = try annotationSnapshot(env)
        let initialPage = pageCount.value as? String
        XCTAssertNotNil(initialPage)
        let document = app.descendants(matching: .any)["reader.document"].firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 20))
        // A multipage fixture is required. Finger gestures scroll with Pencil-only ink.
        for _ in 0..<4 {
            document.swipeUp()
            if pageCount.value as? String != initialPage { break }
        }
        let changedPage = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (pageCount.value as? String) != initialPage
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [changedPage], timeout: 10), .completed)
        XCTAssertEqual(try annotationSnapshot(env), before, "Finger scrolling must not add shared ink")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars.firstMatch.exists)
        XCTAssertTrue(canvas.waitForExistence(timeout: 20))
        XCTAssertTrue(fit.isHittable)
        fit.tap()
        web.buttons["Zoom in"].tap()
        fit.tap()
        // Reopening via the board verifies that its event handlers still work after back.
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        app.buttons["reader.close"].tap()
        // No physical Pencil validation is claimed.
    }

    func testFreshSignupRequestAdmissionAndNativePrivatePaper() throws {
        let env = try fixture()
        let app = XCUIApplication()
        let origin = env["PAPERVIEW_TEST_ORIGIN"]!
        let account = try XCTUnwrap(env["PAPERVIEW_TEST_ACCOUNT_ORIGIN"])
        app.launchArguments = ["--space-test-origin=" + origin, "--accounts-test-origin=" + account,
                               "--space-test-route=/login", "--space-test-clear-web-data"]
        app.launch()
        let web = app.webViews.firstMatch
        let create = web.switches["Create account"]
        XCTAssertTrue(create.waitForExistence(timeout: 20)); create.tap()
        let email = web.textFields["Email"]
        XCTAssertTrue(email.waitForExistence(timeout: 10))
        email.tap(); email.typeText(try XCTUnwrap(env["PAPERVIEW_TEST_SIGNUP_EMAIL"]))
        let nickname = web.textFields["Nickname"]
        nickname.tap(); nickname.typeText("Native Signup")
        let password = web.secureTextFields["Password"]
        password.tap(); password.typeText(try XCTUnwrap(env["PAPERVIEW_TEST_SIGNUP_PASSWORD"]))
        web.buttons["Create account"].tap()
        let requestAccess = web.buttons["Request access"].firstMatch
        XCTAssertTrue(requestAccess.waitForExistence(timeout: 20))
        XCTAssertFalse(web.links["Open"].exists, "New signup must not inherit service admission")
        requestAccess.tap()
        XCTAssertTrue(web.staticTexts["Request pending"].waitForExistence(timeout: 10))
        recordScreenshot(name: "Independent authority pending Space admission")
        // The DGX fixture seeds only this requested Space admission. It does not
        // create membership. A new browser-bound start is required after approval.
        Thread.sleep(forTimeInterval: 5)
        app.terminate()
        let route = try XCTUnwrap(env["PAPERVIEW_TEST_SIGNUP_ROUTE"])
        app.launchArguments = ["--space-test-origin=" + origin, "--accounts-test-origin=" + account,
                               "--space-test-route=/api/accounts/start?return_path=" + route]
        app.launch()
        let join = app.webViews.firstMatch.buttons["Join as Native Signup"]
        XCTAssertTrue(join.waitForExistence(timeout: 25)); join.tap()
        let board = app.webViews.firstMatch
        let canvas = board.descendants(matching: .any)["Drawing canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 30))
        board.buttons["Show space controls"].tap()
        let fit = board.buttons["Fit to content (F)"]
        XCTAssertTrue(fit.waitForExistence(timeout: 30)); fit.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        let count = app.descendants(matching: .any)["reader.page-count"].firstMatch
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (count.value as? String) == "1 of 4"
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 20), .completed)
        recordScreenshot(name: "V2 signup private native PDF")
        app.buttons["reader.close"].tap()
    }

    func testDeniedPaperStillUsesNativeAuthorization() throws {
        let env = try fixture()
        let app = XCUIApplication()
        app.launchArguments = ["--space-test-origin=" + env["PAPERVIEW_TEST_ORIGIN"]!, "--space-test-route=/paper/unauthorized-fixture-paper"]
        app.launch()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        let failure = app.staticTexts["reader.status"]
        XCTAssertTrue(failure.waitForExistence(timeout: 20))
        let denied = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            failure.label.contains("HTTP 404") || failure.label.contains("HTTP 403") || failure.label.contains("HTTP 401")
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [denied], timeout: 20), .completed)
        XCTAssertFalse(app.buttons["reader.tool.pen"].exists)
    }
    private func recordScreenshot(name: String) {
        // Whole-screen capture avoids XCUIElement's rotated-window crop on iPad.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // Test-only independent fixture session. Credentials never enter app bridge code.
    private func annotationSnapshot(_ env: [String: String]) throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let origin = try XCTUnwrap(URL(string: env["PAPERVIEW_TEST_ORIGIN"]!))
        let credentials = try Data(contentsOf: URL(fileURLWithPath: try XCTUnwrap(env["PAPERVIEW_TEST_CREDENTIALS"])))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with: credentials) as? [String: Any])
        let cookies = try XCTUnwrap(fixture["cookies"] as? [[String: String]])
        session.configuration.httpCookieStorage?.setCookies(cookies.compactMap { entry in
            HTTPCookie(properties: [.name: entry["name"]!, .value: entry["value"]!, .domain: "127.0.0.1", .path: "/"])
        }, for: origin, mainDocumentURL: origin)
        let url = origin.appendingPathComponent("api/papers").appendingPathComponent(env["PAPERVIEW_TEST_PAPER"]!)
        let data = try request(URLRequest(url: url), session: session)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let annotations = try XCTUnwrap(json["annotations"] as? [[String: Any]])
        return try JSONSerialization.data(withJSONObject: annotations, options: [.sortedKeys])
    }

    private func request(_ request: URLRequest, session: URLSession) throws -> Data {
        let done = expectation(description: "Fixture request")
        var result: Result<Data, Error>?
        session.dataTask(with: request) { data, response, error in
            if let error { result = .failure(error) }
            else if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data { result = .success(data) }
            else { result = .failure(NSError(domain: "FixtureHTTP", code: (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 20)
        return try XCTUnwrap(result).get()
    }

}
