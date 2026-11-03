import XCTest
import UIKit
import PencilKit
import MeetingBookCore
@testable import MeetingBook

@MainActor final class MixedPageTests: XCTestCase {
    func testMixedSaveReopenAndCommonRenderer() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store=try await NotebookStore.open(root:root)
        let format=UIGraphicsImageRendererFormat();format.scale=1
        let photo=UIGraphicsImageRenderer(size:CGSize(width:200,height:120),format:format).image { renderer in
            UIColor.systemTeal.setFill();renderer.fill(CGRect(x:0,y:0,width:200,height:120))
            "MeetingBook".draw(at:CGPoint(x:20,y:45),withAttributes:[.font:UIFont.systemFont(ofSize:22),.foregroundColor:UIColor.white])
        }
        let image=try await ImageImportService(assets:store.assets).importData(photo.pngData()!)
        let points=[CGPoint(x:80,y:350),CGPoint(x:140,y:300),CGPoint(x:200,y:350),CGPoint(x:260,y:300)]
        let path=PKStrokePath(controlPoints:points.enumerated().map { index,point in PKStrokePoint(location:point,timeOffset:Double(index)*0.1,size:CGSize(width:5,height:5),opacity:1,force:1,azimuth:0,altitude:.pi/2) },creationDate:Date())
        let drawing=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.systemBlue),path:path)])
        let staged=try await store.assets.stage(data:drawing.dataRepresentation()),hash=try await store.assets.finalize(staged)
        var content=PageContent();content.version=2
        let region=content.template.writingRegions[0]
        var block=TextBlock(text:"Meeting notes Äß €\nNative Unicode e\u{301} 👩🏽‍💻 日本語",frame:region.frame)
        block.writingRegionID=region.id;block.baselineIndex=0;block.fontSize=30;block.ink="black"
        content.textBlocks=[block];content.drawingAssetHash=hash
        var element=ImageElement(frame:.init(x:380,y:300,width:240,height:144),zIndex:1,assetHash:image.assetHash,altText:"Teal MeetingBook card")
        element.previewAssetHash=image.previewAssetHash;content.images=[element]
        let note=try await store.createNote(title:"Mixed",contents:[content])
        let reopened=try await NotebookStore.open(root:root),page=try await reopened.openPage(id:note.pages[0].id)
        XCTAssertEqual(page.content,content)
        let resources=try await PageRenderer.resources(for:page.content,store:reopened)
        XCTAssertEqual(resources.drawing.strokes.count,1)
        let preview=try PageRenderer.image(page.content,resources:resources)
        let attachment=XCTAttachment(image:preview);attachment.name="Mixed page native renderer after reopen";attachment.lifetime = .keepAlways;add(attachment)
        XCTAssertEqual(preview.size,CGSize(width:720,height:1000))
        var missing=resources;missing.images=[:]
        XCTAssertThrowsError(try PageRenderer.image(page.content,resources:missing))
    }
}

extension MixedPageTests {
    func testPaperRulingOnlyChangesBackgroundForPlainPages() throws {
        var content=PageContent();content.prepareForEditing();content.textBlocks=[TextBlock(text:"same coordinates")]
        let savedTemplate=content.template,savedText=content.textBlocks
        var samples: [Data]=[]
        for ruling in ["lined","dots","grid"] {
            content.style.ruling=ruling
            samples.append(try PageRenderer.image(content,resources:.init()).pngData()!)
            XCTAssertEqual(content.template,savedTemplate);XCTAssertEqual(content.textBlocks,savedText)
        }
        XCTAssertNotEqual(samples[0],samples[1]);XCTAssertNotEqual(samples[1],samples[2])
        content.template.definitionID="journal.meeting"
        XCTAssertThrowsError(try content.validate())
    }
}

extension MixedPageTests {
    func testUnsupportedLegacyPersonalFontHasReadableFallbackAndWarning() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let staged=try await store.assets.stage(data:Data("legacy unsupported font".utf8)),hash=try await store.assets.finalize(staged)
        let version=FontVersion(assetHash:hash,postScriptName:"Legacy-Unavailable")
        try await store.saveFontProject(FontProject(name:"Legacy",versions:[version]))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Still readable Äß €",fontVersionID:version.id)]
        let note=try await store.createNote(title:"Fallback",contents:[content])
        let resources=try await PageRenderer.resources(for:note.pages[0].content,store:store)
        XCTAssertFalse(resources.fontWarnings.isEmpty)
        XCTAssertNoThrow(try PageRenderer.image(content,resources:resources))
        XCTAssertEqual(content.textBlocks[0].fontVersionID,version.id)
    }
}
