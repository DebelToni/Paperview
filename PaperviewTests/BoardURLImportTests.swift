import XCTest
@testable import Paperview

final class BoardURLImportTests: XCTestCase {
    func testYouTubeURLs() {
        let accepted = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "youtu.be/dQw4w9WgXcQ?t=1",
            "https://m.youtube.com/shorts/dQw4w9WgXcQ", "https://music.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ", "https://youtube.com/live/dQw4w9WgXcQ",
            "https://youtube.co.uk/watch?v=dQw4w9WgXcQ", "https://youtube.com/attribution_link?u=%2Fwatch%3Fv%3DdQw4w9WgXcQ"
        ]
        let rejected = [
            "https://youtube.com.evil.test/watch?v=dQw4w9WgXcQ", "https://evil.test/youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtube.com@evil.test/watch?v=dQw4w9WgXcQ", "https://user@youtube.com/watch?v=dQw4w9WgXcQ",
            "ftp://youtube.com/watch?v=dQw4w9WgXcQ", "https://youtube.com:444/watch?v=dQw4w9WgXcQ",
            "https://youtube.com/watch?v=short", "https://youtu.be/dQw4w9WgXcQ/extra",
            "https://youtube.com/attribution_link?u=https%3A%2F%2Fevil.test%2Fwatch%3Fv%3DdQw4w9WgXcQ"
        ]
        for url in accepted { XCTAssertTrue(BoardURLImports.isYouTube(url), url) }
        for url in rejected { XCTAssertFalse(BoardURLImports.isYouTube(url), url) }
    }
}
