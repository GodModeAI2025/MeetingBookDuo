import XCTest
import MeetingBookCore
@testable import MeetingBook
@MainActor final class ClipboardTests: XCTestCase {
    func testRejectsUnsupportedAndMissingAssets() throws {
        var content=PageContent();content.images=[ImageElement(frame:.init(x:56,y:64,width:100,height:100),assetHash:String(repeating:"a",count:64),altText:"alt")]
        let payload=PageClipboard(content:content,assets:[:],fonts:[])
        XCTAssertThrowsError(try payload.validate())
        var unsupported=PageClipboard(content:PageContent(),assets:[:],fonts:[]);unsupported.version=2
        XCTAssertThrowsError(try unsupported.validate())
    }
}

extension ClipboardTests {
    func testRejectsHashValidButInvalidDrawingBytes() throws {
        let bytes=Data("not PencilKit".utf8),hash=AssetStore.hash(Data("not PencilKit".utf8))
        var content=PageContent();content.drawingAssetHash=hash
        XCTAssertThrowsError(try PageClipboard(content:content,assets:[hash:bytes],fonts:[]).validate())
    }
}
