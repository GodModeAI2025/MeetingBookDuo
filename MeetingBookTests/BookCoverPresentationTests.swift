import XCTest
import SwiftUI
import MeetingBookCore
@testable import MeetingBook

@MainActor final class BookCoverPresentationTests: XCTestCase {
    func testColdStartAndSceneIndependence() {
        let first=BookCoverPresentation(),second=BookCoverPresentation()
        XCTAssertFalse(first.isOpen);first.open();XCTAssertTrue(first.isOpen);XCTAssertFalse(second.isOpen)
        first.close();XCTAssertFalse(first.isOpen)
    }
    func testSyntheticHingeTransitionsPreserveManualChoiceAndReattachment() {
        let model=BookCoverPresentation()
        model.updateHinge(.fullyOpen);XCTAssertTrue(model.isOpen)
        model.close()
        for state:BookCoverPresentation.HingeState? in [.fullyOpen,nil,.unknown,.fullyOpen] {model.updateHinge(state);XCTAssertFalse(model.isOpen)}
        model.updateHinge(.closed);model.open();model.updateHinge(.closed);XCTAssertTrue(model.isOpen)
        model.updateHinge(.partiallyOpen);XCTAssertTrue(model.isOpen)
        model.updateHinge(.closed);XCTAssertFalse(model.isOpen)
        model.updateHinge(.partiallyOpen);XCTAssertTrue(model.isOpen)
    }
    func testUnknownAndLayoutDoNotOpenNotebook() {
        let model=BookCoverPresentation()
        model.updateHinge(nil);model.updateHinge(.unknown);XCTAssertFalse(model.isOpen)
        for width:CGFloat in [0,320,800,1400] {_ = CoverBandGeometry(size:CGSize(width:width,height:500),translation:100,contactY:200)}
        XCTAssertFalse(model.isOpen)
    }
    func testBandBoundsAndReleaseThreshold() {
        let rest=CoverBandGeometry(size:CGSize(width:300,height:500),translation:0,contactY:250)
        let short=CoverBandGeometry(size:CGSize(width:300,height:500),translation:10,contactY:250)
        let full=CoverBandGeometry(size:CGSize(width:300,height:500),translation:120,contactY:250)
        XCTAssertEqual(rest.pull,0);XCTAssertFalse(short.opens);XCTAssertTrue(full.opens)
        XCTAssertGreaterThan(full.contactX,300);XCTAssertLessThan(full.bandWidth,rest.bandWidth)
        for dimension:CGFloat in [0,-100,.infinity,.nan,1e8] {
            let value=CoverBandGeometry(size:CGSize(width:dimension,height:dimension),translation:.infinity,contactY:.nan)
            XCTAssertTrue(value.pull.isFinite);XCTAssertTrue(value.contactX.isFinite);XCTAssertTrue(value.contactY.isFinite)
            XCTAssertFalse(value.opens)
        }
        let left=CoverBandGeometry(size:CGSize(width:300,height:500),translation:-900,contactY:-900)
        XCTAssertFalse(left.opens);XCTAssertGreaterThanOrEqual(left.contactY,0)
    }
    func testNativeCoveredInputRetainsSelectionMarkedTextAndUndo() async throws {
        let store=try await NotebookStore.open(root:FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        var content=PageContent();content.prepareForEditing();let region=content.template.writingRegions[0]
        var block=TextBlock(text:"Größe Ω",frame:region.frame);block.writingRegionID=region.id;block.baselineIndex=0;content.textBlocks=[block]
        let note=try await store.createNote(title:"Cover continuity",contents:[content])
        let session=EditorSession(store:store,snapshot:note);await session.loadFonts();session.selectedElementID=block.id;try await session.setMode(.typing)
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene),controller=PageCanvasController(session:session)
        window.rootViewController=controller;window.makeKeyAndVisible();controller.view.layoutIfNeeded()
        defer {window.isHidden=true}
        let original=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        original.becomeFirstResponder();original.insertText("!");controller.textViewDidChange(original);try await session.flush();controller.refresh()
        var text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        XCTAssertTrue(text.becomeFirstResponder());XCTAssertTrue(text.isFirstResponder)
        text.insertText(" pending");controller.textViewDidChange(text)
        let old=text.inputView,accessory=text.inputAccessoryView
        text.selectedRange=NSRange(location:2,length:2)
        let before=text.selectedRange,canUndo=session.canUndo,value=text.text
        controller.setCoverPresented(true)
        try await session.flush();controller.refresh()
        text=try XCTUnwrap(controller.page.subviews.compactMap{$0 as? TextBlockView}.first)
        XCTAssertNotNil(text.inputView)
        XCTAssertTrue(text.isFirstResponder);XCTAssertEqual(text.selectedRange,before);XCTAssertEqual(text.text,value)
        text.insertText("BLOCKED");XCTAssertEqual(text.text,value)
        controller.setCoverPresented(false)
        XCTAssertTrue(text.inputView === old);XCTAssertTrue(text.inputAccessoryView === accessory)
        XCTAssertEqual(text.selectedRange,before);XCTAssertEqual(session.canUndo,canUndo)
        text.selectedRange=NSRange(location:(text.text as NSString).length,length:0)
        text.setMarkedText("かな",selectedRange:NSRange(location:2,length:0))
        XCTAssertNotNil(text.markedTextRange)
        let marked=text.text
        controller.setCoverPresented(true);controller.setCoverPresented(false)
        XCTAssertEqual(text.text,marked);XCTAssertNotNil(text.markedTextRange)
        text.unmarkText();controller.textViewDidChange(text);try await session.flush()
        XCTAssertEqual(session.activePageID,note.pages[0].id);XCTAssertTrue(session.canUndo)
        try await session.undo();XCTAssertNotEqual(session.activeContent.textBlocks.first?.text,marked)
    }
    func testPublicHingeInteractionIsInstalledOnLocalView() throws {
        guard #available(iOS 27.1,*) else {return}
        let host=UIHostingController(rootView:NotebookHingeObserver(presentation:BookCoverPresentation()))
        let scene=try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap{$0 as? UIWindowScene}.first)
        let window=UIWindow(windowScene:scene);window.rootViewController=host;window.makeKeyAndVisible()
        defer {window.isHidden=true}
        host.loadViewIfNeeded();host.view.frame=CGRect(x:0,y:0,width:300,height:500);host.view.layoutIfNeeded()
        func interactions(_ view:UIView) -> [any UIInteraction] {view.interactions+view.subviews.flatMap{interactions($0)}}
        XCTAssertTrue(interactions(host.view).contains{$0 is UIHingeInteraction})
    }

    func testPhotoCropFollowsFingerAtActualAspectFillScale() {
        let wide=CoverPhotoGeometry(image:CGSize(width:800,height:400),viewport:CGSize(width:300,height:500))
        XCTAssertEqual(wide.renderedSize,CGSize(width:1000,height:500))
        XCTAssertEqual(wide.crop(origin:.zero,translation:CGSize(width:70,height:40)),CGPoint(x:0.2,y:0))
        let tall=CoverPhotoGeometry(image:CGSize(width:400,height:800),viewport:CGSize(width:600,height:300))
        XCTAssertEqual(tall.crop(origin:.zero,translation:CGSize(width:40,height:90)),CGPoint(x:0,y:0.2))
        XCTAssertEqual(tall.crop(origin:.zero,translation:CGSize(width:0,height:9000)),CGPoint(x:0,y:1))
        let invalid=CoverPhotoGeometry(image:.zero,viewport:CGSize(width:CGFloat.infinity,height:0))
        XCTAssertEqual(invalid.crop(origin:.zero,translation:CGSize(width:CGFloat.nan,height:0)),CGPoint.zero)
    }

    func testDiagonalBandTracksCurrentContactAndReturnsToRest() {
        let size=CGSize(width:300,height:500)
        let pulled=CoverBandGeometry(size:size,translation:20,contactY:340)
        XCTAssertEqual(pulled.contactY,340);XCTAssertFalse(pulled.opens)
        let resting=CoverBandGeometry(size:size,translation:0,contactY:250)
        XCTAssertEqual(resting.pull,0);XCTAssertEqual(resting.contactY,250)
    }
    func testInterruptedCropRestartsFromAccumulatedDraft() {
        let geometry=CoverPhotoGeometry(image:CGSize(width:800,height:400),viewport:CGSize(width:300,height:500))
        let draftAtInterruption=geometry.crop(origin:.zero,translation:CGSize(width:70,height:0))
        // GestureState resets the gesture origin on cancellation; the draft remains accumulated.
        XCTAssertEqual(geometry.crop(origin:draftAtInterruption,translation:.zero),draftAtInterruption)
        let resumed=geometry.crop(origin:draftAtInterruption,translation:CGSize(width:35,height:0))
        XCTAssertEqual(resumed.x,0.3,accuracy:0.00001);XCTAssertEqual(resumed.y,0)
    }

}
