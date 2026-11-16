import XCTest
@testable import Paperview

final class NativeRoutingTests: XCTestCase {
    private let bridge = WebBridge(origin:URL(string:"https://space.fixture")!,accountOrigin:URL(string:"https://accounts.fixture")!)
    func testNativeRoutesAreExplicitAndExactOrigin() {
        for (path, expected) in [("/",NativeSpaceRoute.home),("/space/abc-123_",.space("abc-123_")),("/space/abc/",.space("abc")),("/join/invitation",.invitation("invitation"))] {
            XCTAssertEqual(NativeSpaceRoute.parse(URL(string:"https://space.fixture"+path)!,bridge:bridge),expected)
        }
        guard case .paper? = NativeSpaceRoute.parse(URL(string:"https://space.fixture/paper/p")!,bridge:bridge) else { return XCTFail("Native paper route missing") }
        for raw in ["https://accounts.fixture/space/abc","https://external.fixture/space/abc","http://space.fixture/space/abc","https://space.fixture:444/space/abc","https://user:password@space.fixture/space/abc","https://space.fixture/space/abc?extra=1","https://space.fixture/space/abc#fragment","https://space.fixture/space/a%2Fb","https://space.fixture/space/%61","https://space.fixture/space//abc","https://space.fixture/space/abc/extra","https://space.fixture/invite/token","https://space.fixture/settings","https://space.fixture/?extra=1"] {
            XCTAssertNil(NativeSpaceRoute.parse(URL(string:raw)!,bridge:bridge),raw)
        }
    }
}
