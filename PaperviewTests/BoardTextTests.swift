import XCTest
import UIKit
@testable import Paperview

@MainActor
final class BoardTextTests: XCTestCase {
    func testSourceAndBounds() throws {
        let samples = ["# Heading\n\n**bold** *italic* ~~strike~~ [link](https://example.test)", "$$\nx^2+\\frac{1}{2}\n$$\n\ninline $a_b$", "|a|b|\n|-|-|\n|1|2|", "> quote\n\n- one\n- two", "```python\ndef broken(:\n pass\n```", "<unknown data-x='a'>keep</unknown>", "👩🏽‍💻漢字" + String(repeating: "long", count: 100)]
        for source in samples {
            var element = BoardElement(kind: .text); element.text = source
            let layout = try BoardTextLayout(element: element, width: 240)
            XCTAssertEqual(layout.source, source)
            XCTAssertTrue(layout.size.height.isFinite)
            XCTAssertLessThanOrEqual(layout.size.width, 240)
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 240, height: layout.size.height))
            _ = renderer.image { layout.draw(in: $0.cgContext) }
        }
    }
    func testMathErrorDoesNotDisableLayout() throws {
        var element = BoardElement(kind: .text); element.text = "$\\notACommand{x}$ after"
        XCTAssertGreaterThan(try BoardTextLayout(element: element, width: 200).size.height, 0)
    }
    func testRejectBoundsWithoutChangingSource() throws {
        var element = BoardElement(kind: .text); element.text = String(repeating: "x", count: 100001)
        XCTAssertThrowsError(try BoardTextLayout(element: element, width: 100))
        element.text = "unchanged"
        XCTAssertThrowsError(try BoardTextLayout(element: element, width: .nan))
        XCTAssertEqual(element.text, "unchanged")
    }
    func testLinksAreExplicitlyScoped() throws {
        var element = BoardElement(kind: .text); element.text = "[ok](https://example.test) [bad](javascript:alert)"
        let layout = try BoardTextLayout(element: element, width: 200)
        XCTAssertFalse(layout.links.isEmpty)
        XCTAssertTrue(layout.links.allSatisfy { $0.url.scheme == "https" && $0.rect.maxX <= 201 })
    }

    func testEntitiesMatchWebAndPreserveSource() throws {
        XCTAssertEqual(BoardTextLayout.decodeEntities("&AMP; &lt; &#x1f600; &#0; &#55296; &unknown;"), "& < 😀 � � &unknown;")
        var element = BoardElement(kind: .text)
        element.text = "&amp; &#65;"
        let encoded = try BoardTextLayout(element: element, width: 300)
        element.text = "& A"
        let decoded = try BoardTextLayout(element: element, width: 300)
        XCTAssertEqual(encoded.size, decoded.size)
        XCTAssertEqual(encoded.source, "&amp; &#65;")
    }

    func testTableColumnsWrapAndHaveNaturalWidth() throws {
        var element = BoardElement(kind: .text)
        element.text = "| left | right |\n| :--- | ---: |\n| [a](https://a.test) | [b](https://b.test) |\n| [c](https://c.test) | words words words $\\frac{a}{b}$ |"
        let wide = try BoardTextLayout(element: element, width: 1e7)
        let narrow = try BoardTextLayout(element: element, width: 160)
        XCTAssertLessThan(wide.size.width, 2000)
        XCTAssertLessThanOrEqual(narrow.size.width, 160)
        XCTAssertGreaterThan(narrow.size.height, wide.size.height)
        let a = try XCTUnwrap(narrow.links.first { $0.url.host == "a.test" })
        let b = try XCTUnwrap(narrow.links.first { $0.url.host == "b.test" })
        let c = try XCTUnwrap(narrow.links.first { $0.url.host == "c.test" })
        XCTAssertEqual(a.rect.minX, c.rect.minX, accuracy: 1)
        XCTAssertGreaterThan(b.rect.minX, a.rect.maxX)
        XCTAssertGreaterThan(c.rect.minY, a.rect.minY)
        XCTAssertTrue(narrow.links.allSatisfy { $0.rect.maxX <= 161 })
    }

    func testMathCacheDependsOnWidthAndColor() throws {
        var element = BoardElement(kind: .text)
        element.text = "$\\frac{abcdefghijk}{123456789}$"
        element.stroke = "#ff000080"
        let tiny = try BoardTextLayout(element: element, width: 20)
        let wide = try BoardTextLayout(element: element, width: 600)
        XCTAssertGreaterThan(wide.size.width, tiny.size.width * 2)
        element.stroke = "transparent"
        let clear = try BoardTextLayout(element: element, width: 600)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size: clear.size, format: format).image { clear.draw(in: $0.cgContext) }
        let cg = try XCTUnwrap(image.cgImage)
        let data = try XCTUnwrap(cg.dataProvider?.data)
        let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
        XCTAssertTrue((0..<CFDataGetLength(data)).allSatisfy { bytes[$0] == 0 })
        XCTAssertEqual(clear.size, wide.size)
    }
    func testMathSuperscriptRendersAboveBaseGlyph() throws {
        var element = BoardElement(kind:.text); element.text = "$x^2$"; element.fontSize = 40
        let layout = try BoardTextLayout(element:element,width:300)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = false
        let image = UIGraphicsImageRenderer(size:layout.size,format:format).image { layout.draw(in:$0.cgContext) }
        let cg = try XCTUnwrap(image.cgImage), width = cg.width, height = cg.height
        var bytes = [UInt8](repeating:0,count:width*height*4)
        let context = try XCTUnwrap(CGContext(data:&bytes,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(cg,in:CGRect(x:0,y:0,width:width,height:height))
        var leftY = 0.0, rightY = 0.0, leftCount = 0.0, rightCount = 0.0
        for y in 0..<height { for x in 0..<width where bytes[(y*width+x)*4+3] > 64 {
            if x < width/2 { leftY += Double(y); leftCount += 1 }
            else if x > width*2/3 { rightY += Double(y); rightCount += 1 }
        } }
        XCTAssertGreaterThan(leftCount,0); XCTAssertGreaterThan(rightCount,0)
        XCTAssertLessThan(rightY/rightCount,leftY/leftCount-Double(height)*0.1)
    }
    func testMathResourceLimitsPreserveSourceAndKeepLayoutUsable() throws {
        XCTAssertTrue(BoardTextLayout.mathFitsBudget("\\frac{a}{b}"))
        XCTAssertTrue(BoardTextLayout.mathFitsBudget(String(repeating: "\\{", count: 100)))
        for tex in [String(repeating:"{",count:65)+"x"+String(repeating:"}",count:65), String(repeating:"\\sqrt",count:257)+"x", String(repeating:"x",count:4097)] {
            XCTAssertFalse(BoardTextLayout.mathFitsBudget(tex))
            var element = BoardElement(kind:.text); element.text = "$"+tex+"$ after"
            let layout = try BoardTextLayout(element:element,width:300)
            XCTAssertEqual(layout.source,element.text); XCTAssertGreaterThan(layout.size.height,0)
        }
    }
}
