import XCTest

/// End-to-end against disposable actual Space/account services. WebKit is used
/// only for central sign-in; dashboard, board and PDF are native UIKit screens.
final class WebBridgeUITests: XCTestCase {
    private func fixture() throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        for key in ["ORIGIN","ACCOUNT_ORIGIN","EMAIL","PASSWORD","SPACE","PAPER","CREDENTIALS"] {
            guard env["PAPERVIEW_TEST_" + key]?.isEmpty == false else { throw XCTSkip("Missing isolated fixture: \(key)") }
        }
        return env
    }
    private func launch(_ app: XCUIApplication, _ env: [String:String], route: String, clear: Bool = false) {
        app.launchArguments = ["--space-test-origin=" + env["PAPERVIEW_TEST_ORIGIN"]!, "--accounts-test-origin=" + env["PAPERVIEW_TEST_ACCOUNT_ORIGIN"]!, "--space-test-route=" + route]
        if clear { app.launchArguments.append("--space-test-clear-web-data") }
        app.launch()
    }
    private func signIn(_ app: XCUIApplication, _ env: [String:String]) {
        let web = app.webViews.firstMatch
        let email = web.textFields.firstMatch
        XCTAssertTrue(email.waitForExistence(timeout:20)); email.tap(); email.typeText(env["PAPERVIEW_TEST_EMAIL"]!)
        let password = web.secureTextFields.firstMatch
        XCTAssertTrue(password.waitForExistence(timeout:10)); password.tap(); password.typeText(env["PAPERVIEW_TEST_PASSWORD"]!)
        web.buttons["Sign in"].tap()
        XCTAssertTrue(app.tables["space.home"].waitForExistence(timeout:20))
        let noBrowser = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in !app.webViews.firstMatch.exists },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[noBrowser],timeout:10),.completed)
    }
    private func board(_ app: XCUIApplication, _ env: [String:String]) -> XCUIElement {
        let row = app.cells.containing(.staticText,identifier:env["PAPERVIEW_TEST_SPACE"]!).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout:20)); row.tap()
        let canvas = app.descendants(matching:.any)["board.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:20)); XCTAssertTrue(app.buttons["board.tool.pen"].waitForExistence(timeout:20))
        XCTAssertFalse(app.webViews.firstMatch.exists,"A native board must not mount a webpage renderer")
        return canvas
    }
    private func fit(_ app: XCUIApplication) {
        app.buttons["board.more"].tap()
        let view = app.buttons["View"]
        XCTAssertTrue(view.waitForExistence(timeout:5)); view.tap()
        let fit = app.buttons["Fit to content"]
        XCTAssertTrue(fit.waitForExistence(timeout:5)); fit.tap()
    }
    func testFingerShapeCreation() throws {
        XCUIDevice.shared.orientation = .portrait
        let env = try fixture(), app = XCUIApplication()
        launch(app, env, route: "/login", clear: true); signIn(app, env)
        let canvas = board(app, env); fit(app)
        app.buttons["board.tool.rectangle"].tap()
        XCTAssertTrue(app.buttons["board.tool.rectangle"].isSelected)
        let from = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.08))
        let to = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.15))
        from.press(forDuration: 0.1, thenDragTo: to)
        try waitForBoard(env) { $0.contains { ($0["kind"] as? String) == "rectangle" && ($0["deleted"] as? Bool) == false } }
        app.buttons["board.undo"].tap()
    }
    func testLiveBoardToNativeReaderAndBack() throws {
        XCUIDevice.shared.orientation = .portrait
        let env = try fixture(), app = XCUIApplication()
        launch(app,env,route:"/login",clear:true); signIn(app,env)
        let canvas = board(app,env); fit(app)
        let beforeBoard = try boardSnapshot(env), beforeNotes = try annotationSnapshot(env)
        XCTAssertTrue(app.buttons["board.tool.pen"].isSelected)
        let beforePan = canvas.value as? String
        canvas.swipeUp()
        XCTAssertNotEqual(canvas.value as? String, beforePan, "A finger pan must move the viewport, not merely avoid drawing")
        fit(app)
        XCTAssertEqual(try boardSnapshot(env),beforeBoard,"Finger navigation while Pen is selected cannot add ink")
        recordScreenshot("Native board")
        canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout:20))
        XCTAssertFalse(app.webViews.firstMatch.exists)
        let count = app.descendants(matching:.any)["reader.page-count"].firstMatch
        XCTAssertTrue(count.waitForExistence(timeout:20))
        let ready = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in (count.value as? String)?.hasSuffix(" of 4") == true },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[ready],timeout:20),.completed)
        // Reader position survives app launches. Navigate explicitly rather than
        // assuming an earlier test left the paper on its first page.
        for _ in 0..<3 {
            if count.value as? String == "1 of 4" { break }
            let previous = app.buttons["reader.previous-page"]
            if previous.isEnabled { previous.tap() }
        }
        let loaded = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in count.value as? String == "1 of 4" },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[loaded],timeout:20),.completed)
        XCUIDevice.shared.orientation = .landscapeLeft
        app.buttons["reader.thinner"].tap(); app.buttons["reader.thicker"].tap()
        recordScreenshot("Native PDF landscape")
        XCUIDevice.shared.orientation = .portrait
        let document = app.descendants(matching:.any)["reader.document"].firstMatch
        for _ in 0..<4 { document.swipeUp(); if count.value as? String != "1 of 4" { break } }
        XCTAssertNotEqual(count.value as? String,"1 of 4")
        XCTAssertEqual(try annotationSnapshot(env),beforeNotes)
        app.buttons["reader.close"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout:20)); XCTAssertFalse(app.webViews.firstMatch.exists)
        fit(app); canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout:20)); app.buttons["reader.close"].tap()

        // Trusted finger events exercise the native object tool, journal, Rust engine,
        // API save and conditional undo without claiming physical Pencil validation.
        app.buttons["board.tool.rectangle"].tap()
        let a = canvas.coordinate(withNormalizedOffset:CGVector(dx:0.15,dy:0.08)), b = canvas.coordinate(withNormalizedOffset:CGVector(dx:0.3,dy:0.15))
        a.press(forDuration:0.1,thenDragTo:b)
        try waitForBoard(env) { $0.contains { ($0["kind"] as? String) == "rectangle" && ($0["deleted"] as? Bool) == false } }
        let createdBoard = try XCTUnwrap(payload(env, path: "spaces/" + spaceID(env))["board"] as? [String: Any])
        let rectangle = try XCTUnwrap((createdBoard["elements"] as? [[String: Any]])?.first { ($0["kind"] as? String) == "rectangle" && ($0["deleted"] as? Bool) == false })
        let rectangleID = try XCTUnwrap(rectangle["id"] as? String), originalX = try XCTUnwrap(rectangle["x"] as? Double)
        // The context-menu recognizer must not cancel an ordinary object drag.
        app.buttons["board.tool.select"].tap()
        a.press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.08)))
        try waitForBoard(env) { $0.contains { ($0["id"] as? String) == rectangleID && ($0["x"] as? Double) != originalX } }
        app.buttons["board.undo"].tap()
        try waitForBoard(env) { $0.contains { ($0["id"] as? String) == rectangleID && ($0["x"] as? Double) == originalX } }
        app.buttons["board.undo"].tap()
        try waitForBoard(env) { !$0.contains { ($0["kind"] as? String) == "rectangle" && ($0["deleted"] as? Bool) == false } }
        app.buttons["board.redo"].tap()
        try waitForBoard(env) { $0.contains { ($0["kind"] as? String) == "rectangle" && ($0["deleted"] as? Bool) == false } }
        app.buttons["board.undo"].tap()

        app.buttons["board.tool.text"].tap(); a.tap()
        let editor = app.textViews["board.text-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout:10))
        let source = "v p t f 123 native **text** $x^2$"
        editor.typeText(source)
        XCTAssertEqual(editor.value as? String,source,"Bare board shortcuts cannot intercept native text entry")
        app.toolbars.buttons["Done"].tap()
        try waitForBoard(env) { $0.contains { ($0["kind"] as? String) == "text" && ($0["text"] as? String) == source && ($0["deleted"] as? Bool) == false } }
        XCTAssertFalse(app.webViews.firstMatch.exists)
        recordScreenshot("Native object and rich-text editing")
        app.buttons["board.tool.text"].tap(); a.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.typeText("Tool switch retains draft")
        app.buttons["board.tool.rectangle"].tap()
        try waitForBoard(env) { $0.contains { ($0["text"] as? String) == "Tool switch retains draft" && ($0["deleted"] as? Bool) == false } }
        XCTAssertFalse(editor.exists)
        XCTAssertTrue(app.buttons["board.tool.rectangle"].isSelected)
        app.buttons["board.undo"].tap()
        app.buttons["board.undo"].tap()
        try waitForBoard(env) { !$0.contains { ($0["kind"] as? String) == "text" && ($0["text"] as? String) == source && ($0["deleted"] as? Bool) == false } }
    }
    func testPaperListSelectionAndUnchangedPolling() throws {
        XCUIDevice.shared.orientation = .portrait
        let env = try fixture(), app = XCUIApplication()
        launch(app, env, route: "/login", clear: true); signIn(app, env)
        let canvas = board(app, env); fit(app)
        let original = try boardSnapshot(env)

        app.buttons["board.papers"].tap()
        let papers = app.tables["board.papers-list"]
        XCTAssertTrue(papers.waitForExistence(timeout: 10))
        let row = papers.cells["board.paper." + env["PAPERVIEW_TEST_PAPER"]!]
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.tap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        XCTAssertFalse(papers.exists, "Paper selection must dismiss the sheet before opening the reader")
        app.buttons["reader.close"].tap()
        XCTAssertTrue(canvas.waitForExistence(timeout: 10))

        fit(app); app.buttons["board.tool.select"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let open = app.buttons["board.open-paper"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["board.selection"].exists)
        // Several real collaboration polls must leave selection and menus usable.
        app.buttons["board.selection"].tap()
        let menuOpen = app.collectionViews.buttons["Open PDF"]
        XCTAssertTrue(menuOpen.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 7)
        XCTAssertTrue(menuOpen.exists, "An unchanged poll must not tear down a presented menu")
        menuOpen.tap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        app.buttons["reader.close"].tap()
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.tap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        app.buttons["reader.close"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1)
        XCTAssertTrue(menuOpen.waitForExistence(timeout: 5)); menuOpen.tap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout: 20))
        app.buttons["reader.close"].tap()
        XCTAssertEqual(try boardSnapshot(env), original, "Navigation and idle polls must not mutate the shared board")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "conflict")).firstMatch.exists)
        recordScreenshot("Board selection and direct PDF navigation")
    }
    func testWebBoardNativeEditDoesNotRewriteExistingElements() throws {
        let env = try fixture()
        guard let space = env["PAPERVIEW_TEST_INTEROP_SPACE"] else { throw XCTSkip("Missing web-created interoperability fixture") }
        let path = "spaces/" + space
        let before = try XCTUnwrap(payload(env, path: path)["board"] as? [String: Any])
        let originals = try XCTUnwrap(before["elements"] as? [[String: Any]])
        let app = XCUIApplication(); launch(app, env, route: "/login", clear: true); signIn(app, env)
        app.terminate(); launch(app, env, route: "/space/" + space)
        let canvas = app.descendants(matching: .any)["board.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout: 20)); fit(app)
        Thread.sleep(forTimeInterval: 7)
        let idle = try XCTUnwrap(payload(env, path: path)["board"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: before, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: idle, options: [.sortedKeys]))
        recordScreenshot("Web-created mixed board in native canvas")
        app.buttons["board.tool.rectangle"].tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.7)).press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.8)))
        let deadline = Date().addingTimeInterval(20)
        var after: [[String: Any]] = []
        repeat {
            let value = try XCTUnwrap(payload(env, path: path)["board"] as? [String: Any])
            after = try XCTUnwrap(value["elements"] as? [[String: Any]])
            if after.count > originals.count { break }
            Thread.sleep(forTimeInterval: 0.25)
        } while Date() < deadline
        XCTAssertEqual(after.count, originals.count + 1)
        for original in originals {
            let match = try XCTUnwrap(after.first { ($0["id"] as? String) == (original["id"] as? String) })
            XCTAssertEqual(try JSONSerialization.data(withJSONObject: original, options: [.sortedKeys]), try JSONSerialization.data(withJSONObject: match, options: [.sortedKeys]), "Native edit must preserve every existing web element exactly")
        }
        recordScreenshot("Native edit on shared web board")
    }
    func testFreshSignupRequestAdmissionAndNativePrivatePaper() throws {
        let env = try fixture()
        for key in ["SIGNUP_EMAIL","SIGNUP_PASSWORD","SIGNUP_ROUTE"] { guard env["PAPERVIEW_TEST_" + key] != nil else { throw XCTSkip("Missing fresh signup fixture") } }
        let app = XCUIApplication(); launch(app,env,route:"/login",clear:true)
        let web = app.webViews.firstMatch, create = web.switches["Create account"]
        XCTAssertTrue(create.waitForExistence(timeout:20)); create.tap()
        let email = web.textFields["Email"]; XCTAssertTrue(email.waitForExistence(timeout:10)); email.tap(); email.typeText(env["PAPERVIEW_TEST_SIGNUP_EMAIL"]!)
        let nickname = web.textFields["Nickname"]; nickname.tap(); nickname.typeText("Native Signup")
        let password = web.secureTextFields["Password"]; password.tap(); password.typeText(env["PAPERVIEW_TEST_SIGNUP_PASSWORD"]!)
        web.buttons["Create account"].tap()
        let request = web.buttons["Request access"].firstMatch
        XCTAssertTrue(request.waitForExistence(timeout:20)); request.tap()
        XCTAssertTrue(web.staticTexts["Request pending"].waitForExistence(timeout:10))
        recordScreenshot("Independent account admission")
        Thread.sleep(forTimeInterval:5)
        app.terminate()
        launch(app,env,route:"/api/accounts/start?return_path=" + env["PAPERVIEW_TEST_SIGNUP_ROUTE"]!)
        let join = app.alerts.buttons["Join as Native Signup"]
        XCTAssertTrue(join.waitForExistence(timeout:25)); join.tap()
        let canvas = app.descendants(matching:.any)["board.canvas"].firstMatch
        XCTAssertTrue(canvas.waitForExistence(timeout:20)); XCTAssertFalse(app.webViews.firstMatch.exists)
        fit(app); canvas.coordinate(withNormalizedOffset:CGVector(dx:0.5,dy:0.5)).doubleTap()
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout:20)); app.buttons["reader.close"].tap()
    }
    func testDeniedPaperStillUsesNativeAuthorization() throws {
        let env = try fixture(), app = XCUIApplication()
        launch(app,env,route:"/paper/unauthorized-fixture-paper")
        XCTAssertTrue(app.otherElements["paper.reader"].waitForExistence(timeout:20))
        let status = app.staticTexts["reader.status"]
        let denied = XCTNSPredicateExpectation(predicate:NSPredicate { _,_ in status.label.contains("HTTP 404") || status.label.contains("HTTP 403") || status.label.contains("HTTP 401") },object:nil)
        XCTAssertEqual(XCTWaiter.wait(for:[denied],timeout:20),.completed)
        XCTAssertFalse(app.buttons["reader.tool.pen"].exists)
    }
    private func recordScreenshot(_ name:String) { let attachment = XCTAttachment(screenshot:XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment) }
    private func payload(_ env:[String:String],path:String) throws -> [String:Any] {
        let credentials = try Data(contentsOf:URL(fileURLWithPath:env["PAPERVIEW_TEST_CREDENTIALS"]!))
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(with:credentials) as? [String:Any])
        let cookies = try XCTUnwrap(fixture["cookies"] as? [[String:String]])
        let origin = try XCTUnwrap(URL(string:env["PAPERVIEW_TEST_ORIGIN"]!))
        var request = URLRequest(url:origin.appendingPathComponent("api/" + path))
        request.setValue(cookies.map { ($0["name"] ?? "") + "=" + ($0["value"] ?? "") }.joined(separator:"; "),forHTTPHeaderField:"Cookie")
        let session = URLSession(configuration:.ephemeral); defer { session.invalidateAndCancel() }
        let done = expectation(description:"Synthetic fixture read"); var response:Result<Data,Error>?
        session.dataTask(with:request) { data,reply,error in
            if let error { response = .failure(error) }
            else if let http = reply as? HTTPURLResponse, (200..<300).contains(http.statusCode), let data { response = .success(data) }
            else { response = .failure(NSError(domain:"FixtureHTTP",code:(reply as? HTTPURLResponse)?.statusCode ?? 0)) }
            done.fulfill()
        }.resume()
        wait(for:[done],timeout:30)
        return try XCTUnwrap(JSONSerialization.jsonObject(with:XCTUnwrap(response).get()) as? [String:Any])
    }
    private func spaceID(_ env:[String:String]) throws -> String {
        let data = try Data(contentsOf:URL(fileURLWithPath:env["PAPERVIEW_TEST_CREDENTIALS"]!))
        return try XCTUnwrap((JSONSerialization.jsonObject(with:data) as? [String:Any])?["spaceID"] as? String)
    }
    private func boardSnapshot(_ env:[String:String]) throws -> Data {
        let object = try XCTUnwrap(payload(env,path:"spaces/" + spaceID(env))["board"] as? [String:Any])
        return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
    }
    private func annotationSnapshot(_ env:[String:String]) throws -> Data {
        try JSONSerialization.data(withJSONObject:XCTUnwrap(payload(env,path:"papers/" + env["PAPERVIEW_TEST_PAPER"]!)["annotations"]),options:[.sortedKeys])
    }
    private func waitForBoard(_ env:[String:String],test:([[String:Any]])->Bool) throws {
        let deadline = Date().addingTimeInterval(20)
        repeat {
            let object = try XCTUnwrap(payload(env,path:"spaces/" + spaceID(env))["board"] as? [String:Any])
            if let elements = object["elements"] as? [[String:Any]], test(elements) { return }
            Thread.sleep(forTimeInterval:0.25)
        } while Date() < deadline
        XCTFail("Native edit did not reach the revision-safe server board")
    }
}
