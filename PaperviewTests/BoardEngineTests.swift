import XCTest
@testable import Paperview

@MainActor final class BoardEngineTests: XCTestCase {
    private func box(_ id: String = "box", x: Double = 10, y: Double = 20) -> BoardElement {
        var element = BoardElement(kind: .rectangle, id: id)
        element.x = x; element.y = y; element.width = 100; element.height = 80
        return element
    }
    func testNativeCreateMoveUndoAndResolvedArrowBinding() throws {
        var target = box()
        target.fill = "#ffffff"
        var arrow = BoardElement(kind: .arrow, id: "arrow")
        arrow.x = 110; arrow.y = 60; arrow.width = 90; arrow.points = [[0,0],[90,0]]; arrow.z = 2
        arrow.startAnchor = BoardAnchor(elementId: "box", x: 1, y: 0.5)
        let engine = try BoardEngine(board: BoardDocument(elements: [target,arrow]))
        XCTAssertEqual(try engine.hit(BoardPoint(x: 20,y:30),tolerance:1),"box")
        XCTAssertEqual(try engine.query(BoardRect(x:0,y:0,width:300,height:300)).first?.element.kind,.rectangle)
        try engine.apply(.move(["box"],dx:40,dy:10))
        let item = try XCTUnwrap(engine.query(BoardRect(x:0,y:0,width:300,height:300)).first(where:{$0.element.id == "arrow"}))
        XCTAssertEqual(item.points?.first,[150,70])
        try engine.undo()
        XCTAssertEqual(engine.board.element("box")?.x,10)
        try engine.redo()
        XCTAssertEqual(engine.board.element("box")?.x,50)
    }
    func testConditionalUndoRetainsIndependentRemoteObjects() throws {
        let engine = try BoardEngine(board:BoardDocument(elements:[box()]))
        try engine.apply(.move(["box"],dx:30,dy:0))
        var remote = engine.board; remote.elements.append(box("other",x:300))
        try engine.replace(remote)
        try engine.undo()
        XCTAssertEqual(engine.board.element("box")?.x,10)
        XCTAssertEqual(engine.board.element("other")?.x,300)
    }
    func testConflictingRemoteObjectCannotBeUndone() throws {
        let engine = try BoardEngine(board:BoardDocument(elements:[box()]))
        try engine.apply(.move(["box"],dx:30,dy:0))
        var remote = engine.board
        remote.elements[0].x += 5; remote.elements[0].version += 1
        try engine.replace(remote)
        XCTAssertThrowsError(try engine.undo())
        XCTAssertEqual(engine.board,remote)
    }
    func testNativeCommandsEncodeExactWireShapes() throws {
        let commands:[BoardCommand] = [.put([box()]),.delete(["box"]),.move(["box"],dx:2,dy:3),.resize(id:"box",rect:BoardRect(x:0,y:0,width:20,height:30)),.group(["a","b"],groupId:"g"),.ungroup(["a","b"]),.resizeGroup(["a","b"],rect:BoardRect(x:0,y:0,width:20,height:30)),.batch([.delete(["box"])])]
        let names = ["put","delete","move","resize","group","ungroup","resizegroup","batch"]
        for (command,name) in zip(commands,names) {
            let data = try JSONEncoder().encode(command)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
            XCTAssertEqual(object["type"] as? String,name)
            let roundtrip = try JSONDecoder().decode(BoardCommand.self,from:data)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            XCTAssertEqual(try encoder.encode(command),try encoder.encode(roundtrip))
        }
    }
    func testOptionalFieldsAndPenDotRoundTrip() throws {
        var element = BoardElement(kind:.pen,id:"dot"); element.points = [[0,0]]; element.x = -30; element.y = 60
        let engine = try BoardEngine(board:BoardDocument(elements:[element]))
        XCTAssertEqual(try engine.hit(BoardPoint(x:-30,y:60),tolerance:1),"dot")
        let data = try JSONEncoder().encode(engine.board)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:data) as? [String:Any])
        let item = try XCTUnwrap((object["elements"] as? [[String:Any]])?.first)
        XCTAssertNil(item["autoFontSize"]); XCTAssertNil(item["textWrapWidth"])
        XCTAssertEqual(try JSONDecoder().decode(BoardDocument.self,from:data),engine.board)
    }
    func testInvalidDocumentFailsWithoutFallback() throws {
        var invalid = box(); invalid.width = -1
        XCTAssertThrowsError(try BoardEngine(board:BoardDocument(elements:[invalid])))
    }
    func testGroupingAndLegacyKindsRemainEditable() throws {
        let engine = try BoardEngine(board:.empty)
        for (index,kind) in [BoardKind.ellipse,.diamond,.line].enumerated() {
            var element = BoardElement(kind:kind,id:"legacy\(index)"); element.x = Double(index)*200; element.width = 80; element.height = 80
            if kind == .line { element.points = [[0,0],[80,80]] }
            try engine.apply(.put([element]))
        }
        try engine.apply(.group(["legacy0","legacy1"],groupId:"g"))
        try engine.apply(.move(["legacy0"],dx:10,dy:5))
        XCTAssertEqual(engine.board.element("legacy1")?.x,210)
        try engine.apply(.ungroup(["legacy0"]))
        XCTAssertNil(engine.board.element("legacy1")?.groupId)
    }
}
