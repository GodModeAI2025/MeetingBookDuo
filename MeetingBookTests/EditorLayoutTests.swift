import XCTest
import UIKit
import MeetingBookCore
@testable import MeetingBook

@MainActor final class EditorLayoutTests: XCTestCase {
    func testActualNativeBaselinesAndComposedOverflow() throws {
        for size in [24.0,30,36] {
            var content=PageContent();let region=content.template.writingRegions[0]
            var block=TextBlock(text:String(repeating:"Äß e\u{301} 👩🏽‍💻 日本語 ",count:200),frame:region.frame)
            block.fontSize=size;block.writingRegionID=region.id;block.baselineIndex=0
            let view=TextBlockView(block:block,content:content,versions:[])
            let measurements=view.canonicalBaselines()
            XCTAssertGreaterThan(measurements.count,1)
            for (actual,expected) in zip(measurements,region.baselines) { XCTAssertEqual(actual,expected,accuracy:0.5) }
            let chunks=try TextBlockView.paginate(block:block,content:content,versions:[])
            XCTAssertEqual(chunks.map(\.text).joined().unicodeScalars.map(\.value),block.text.unicodeScalars.map(\.value))
            XCTAssertGreaterThan(chunks.count,1)
            content.textBlocks=[block]
        }
    }
    func testMarkedTextAndCaretRetainedDuringResize() throws {
        let content=PageContent();var block=TextBlock(text:"Text\n",frame:content.template.writingRegions[0].frame)
        block.writingRegionID=content.template.writingRegions[0].id;block.baselineIndex=0
        let view=TextBlockView(block:block,content:content,versions:[])
        view.selectedRange=NSRange(location:5,length:0)
        view.setMarkedText("に",selectedRange:NSRange(location:1,length:0))
        XCTAssertNotNil(view.markedTextRange)
        view.frame.size.width=300;view.layoutIfNeeded()
        XCTAssertNotNil(view.markedTextRange)
        view.unmarkText();XCTAssertTrue(view.text.contains("に"))
        let caret=view.caretRect(for:view.endOfDocument)
        XCTAssertTrue(caret.minY.isFinite);XCTAssertGreaterThan(caret.height,0)
    }
}

extension EditorLayoutTests {
    func testStoredNonuniformRegionAndTrailingCaret() throws {
        var content=PageContent();content.version=2
        let region=WritingRegion(frame:.init(x:80,y:90,width:300,height:400),baselines:[130,180,240,310,380,450])
        content.template.writingRegions=[region]
        var block=TextBlock(text:"First\nSecond\nThird",frame:region.frame);block.writingRegionID=region.id;block.baselineIndex=0;block.fontSize=30
        let view=TextBlockView(block:block,content:content,versions:[])
        XCTAssertEqual(view.canonicalBaselines(),[130,180,240])
        view.selectedRange=NSRange(location:(view.text as NSString).length,length:0)
        let caret=view.caretRect(for:view.endOfDocument)
        XCTAssertEqual(caret.maxY+view.frame.minY,240,accuracy:12)
        block.text += "\n"
        let trailing=TextBlockView(block:block,content:content,versions:[])
        let extra=trailing.caretRect(for:trailing.endOfDocument)
        XCTAssertEqual(extra.minY+trailing.font!.ascender+region.frame.y,310,accuracy:0.5)
    }
}

extension EditorLayoutTests {
    func testNativeViewportTransformInverseAndStoredCoordinates() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let note=try await store.createNote(title:"Resize",contents:[PageContent()])
        let session=EditorSession(store:store,snapshot:note),controller=PageCanvasController(session:session)
        controller.loadViewIfNeeded()
        for size in [CGSize(width:375,height:667),CGSize(width:600,height:900),CGSize(width:1024,height:768),CGSize(width:1366,height:1024)] {
            controller.view.frame=CGRect(origin:.zero,size:size);controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
            let canonical=CGPoint(x:56,y:104)
            let display=controller.page.convert(canonical,to:controller.view),inverse=controller.view.convert(display,to:controller.page)
            XCTAssertEqual(inverse.x,canonical.x,accuracy:0.5);XCTAssertEqual(inverse.y,canonical.y,accuracy:0.5)
            XCTAssertEqual(session.activeContent,note.pages[0].content)
            session.largerReadingView=true;controller.view.setNeedsLayout();controller.view.layoutIfNeeded()
            XCTAssertEqual(controller.page.transform.a,2*controller.scroll.bounds.width/720,accuracy:0.001)
            session.largerReadingView=false
        }
    }
}

extension EditorLayoutTests {
    func testTallFallbackInkIsReportedWithoutTruncatingUnicode() throws {
        let content=PageContent(),region=PageContent().template.writingRegions[0]
        var page=content;page.template.writingRegions=[region]
        var block=TextBlock(text:"A"+String(repeating:"\u{0301}",count:30),frame:region.frame)
        block.fontSize=36;block.writingRegionID=region.id;block.baselineIndex=0
        XCTAssertThrowsError(try TextBlockView.paginate(block:block,content:page,versions:[]))
        XCTAssertEqual(block.text.unicodeScalars.count,31)
    }
}

extension EditorLayoutTests {
    func testExplicitFontApplyPreservesNativeSelectedRange() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"Selected text")];content.prepareForEditing()
        let note=try await store.createNote(title:"Selection",contents:[content]),session=EditorSession(store:store,snapshot:note)
        try await session.setMode(.typing)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        let field=try XCTUnwrap(controller.page.subviews.compactMap { $0 as? TextBlockView }.first)
        field.selectedRange=NSRange(location:2,length:4)
        let preview=try session.preview(pageIDs:[session.activePageID]) { $0.textBlocks[0].fontSize=36 }
        try await session.apply(preview);controller.refresh()
        let changed=try XCTUnwrap(controller.page.subviews.compactMap { $0 as? TextBlockView }.first)
        XCTAssertEqual(changed.selectedRange,NSRange(location:2,length:4))
    }
}

extension EditorLayoutTests {
    func testLegacyPositionedFrameDerivesStoredRegionWithoutMoving() throws {
        let content=PageContent(),frame=PageRect(x:100,y:120,width:200,height:200)
        let block=TextBlock(text:"Legacy positioned",frame:frame)
        let chunks=try TextBlockView.paginate(block:block,content:content,versions:[])
        XCTAssertEqual(chunks.first?.frame,frame);XCTAssertEqual(chunks.map(\.text).joined(),block.text)
        let native=TextBlockView(block:block,content:content,versions:[])
        XCTAssertEqual(native.canonicalBaselines().first,184)
    }
}

extension EditorLayoutTests {
    func testCompletePageRenderRejectsHiddenOverflow() throws {
        let content=PageContent(),region=content.template.writingRegions[0]
        var block=TextBlock(text:String(repeating:"Overflow\n",count:100),frame:region.frame)
        block.writingRegionID=region.id;block.baselineIndex=0
        let view=TextBlockView(block:block,content:content,versions:[])
        XCTAssertThrowsError(try view.validateVisibleContent())
        XCTAssertGreaterThan(try TextBlockView.paginate(block:block,content:content,versions:[]).count,1)
    }
}

extension EditorLayoutTests {
    func testNativeReconciliationPreservesExactUnicode() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.textBlocks=[TextBlock(text:"\u{e9}")]
        let note=try await store.createNote(title:"Native exact",contents:[content]),session=EditorSession(store:store,snapshot:note)
        let controller=PageCanvasController(session:session);controller.loadViewIfNeeded()
        content.textBlocks[0].text="e\u{301}";session.setDraft(content,pageID:note.pages[0].id);controller.refresh()
        let field=try XCTUnwrap(controller.page.subviews.compactMap { $0 as? TextBlockView }.first)
        XCTAssertEqual(field.text.unicodeScalars.map(\.value),[0x65,0x301])
        try await session.flush();try await session.undo();controller.refresh()
        XCTAssertEqual(field.text.unicodeScalars.map(\.value),[0xe9])
        try await session.redo();controller.refresh()
        XCTAssertEqual(field.text.unicodeScalars.map(\.value),[0x65,0x301])
    }
}
