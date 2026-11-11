import XCTest
import WebKit
@testable import Paperview

@MainActor
final class BrowserConfigurationTests: XCTestCase {
    func testBoardAllowsInlineSilentMediaButRequiresAudioGesture() throws {
        let browser = BrowserController()
        browser.loadViewIfNeeded()
        let web = try XCTUnwrap(browser.view as? WKWebView)
        XCTAssertTrue(web.configuration.allowsInlineMediaPlayback)
        XCTAssertEqual(web.configuration.mediaTypesRequiringUserActionForPlayback, .audio)
    }
}
