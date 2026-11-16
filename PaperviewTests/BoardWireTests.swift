import XCTest
@testable import Paperview

final class BoardWireTests: XCTestCase {
    private func wire() throws -> [String: Any] {
        var element = BoardElement(kind: .text, id: "text")
        element.text = "α & β\n$x^2$"; element.fontSize = 24; element.autoFontSize = true; element.textWrapWidth = 0
        return try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(element)) as? [String: Any])
    }
    func testUnknownPortableElementFieldsStopEditing() throws {
        var data = try wire(); data["futureInk"] = ["pressure": [0.4, 0.8]]
        XCTAssertThrowsError(try JSONDecoder().decode(BoardElement.self, from: JSONSerialization.data(withJSONObject: data)))
    }
    func testExplicitNullOptionalFieldsAreNotSilentlyDropped() throws {
        for name in ["groupId","bold","italic","strokeStyle","diagramType","videoAutoplay","text","fontSize","autoFontSize","textWrapWidth","fontFamily","url","assetId","paperId","paperView","paperTitle","points","startAnchor","endAnchor"] {
            var data = try wire(); data[name] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(BoardElement.self, from: JSONSerialization.data(withJSONObject: data)), name)
        }
    }
    func testAllBaseFieldsRemainRequired() throws {
        for name in ["id","kind","x","y","width","height","angle","stroke","fill","strokeWidth","opacity","z","version","deleted","locked"] {
            var data = try wire(); data.removeValue(forKey: name)
            XCTAssertThrowsError(try JSONDecoder().decode(BoardElement.self, from: JSONSerialization.data(withJSONObject: data)), name)
        }
    }
    func testUnicodeAndOptionalOmissionRoundTripExactly() throws {
        let data = try JSONSerialization.data(withJSONObject: wire())
        let decoded = try JSONDecoder().decode(BoardElement.self, from: data)
        XCTAssertEqual(decoded.text,"α & β\n$x^2$"); XCTAssertEqual(decoded.textWrapWidth,0)
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNil(result["groupId"]); XCTAssertNil(result["bold"]); XCTAssertEqual(result["autoFontSize"] as? Bool,true)
    }
    func testUnknownDocumentAssetAndAnchorFieldsReject() throws {
        let fixtures = [#"{"version":1,"elements":[],"assets":{},"future":1}"#, #"{"mimeType":"image/png","dataURL":"data:image/png;base64,AAAA","future":1}"#, #"{"elementId":"a","x":0,"y":0,"future":1}"#]
        XCTAssertThrowsError(try JSONDecoder().decode(BoardDocument.self,from:Data(fixtures[0].utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BoardAsset.self,from:Data(fixtures[1].utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(BoardAnchor.self,from:Data(fixtures[2].utf8)))
    }
    func testBooleanAndUnknownKindAreStrict() throws {
        var data = try wire(); data["bold"] = 1
        XCTAssertThrowsError(try JSONDecoder().decode(BoardElement.self,from:JSONSerialization.data(withJSONObject:data)))
        data = try wire(); data["kind"] = "futureShape"
        XCTAssertThrowsError(try JSONDecoder().decode(BoardElement.self,from:JSONSerialization.data(withJSONObject:data)))
    }
}
